"""
Webhook Receiver.
Accepts GET/POST on /{slug}/{secret}.
Immediately pushes raw data to Redis queue and returns 200.
"""
import base64
import hashlib
import hmac
import json
import logging
import os
import re
import time
from contextlib import asynccontextmanager
from typing import Any
from urllib.parse import parse_qsl

import redis.asyncio as aioredis
from fastapi import FastAPI, Request
from fastapi.responses import PlainTextResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.config import get_network

logging.basicConfig(level=logging.WARNING)
logger = logging.getLogger("webhook.receiver")

REDIS_URL = os.environ.get("REDIS_URL", "redis://localhost:6379/0")
QUEUE_KEY = "webhook:queue"
RATE_LIMIT_PREFIX = "webhook:rl:"
# F-S1-009 defense-in-depth: per-IP лимит до per-slug. Защищает quota slug'а
# от исчерпания одним атакующим, который скомпрометировал slug+secret.
# 120/min — щедро для CPA-сетей (Admitad/EPN могут шлёт burst'ы), но
# отлавливает любой single-source flood.
RATE_LIMIT_IP_PREFIX = "webhook:rl:ip:"
RATE_LIMIT_IP_MAX = 120  # req/min per IP (across all slugs)
# Реальные постбэки CPA-сетей < 4 KB; 16 KB — щедрый запас. Защита от DoS:
# attacker не может слить event loop чтением мегабайтного тела.
MAX_PAYLOAD_BYTES = 16 * 1024

# Lua script: atomic INCR + EXPIRE (only sets TTL on first request)
_RL_LUA = """
local current = redis.call('INCR', KEYS[1])
if current == 1 then
    redis.call('EXPIRE', KEYS[1], 60)
end
return current
"""


def _client_ip(request: Request) -> str:
    """Извлечь IP клиента CPA с учётом Traefik upstream.

    Webhook receiver экспонируется только через Traefik (Host()-правило);
    request.client.host = IP Traefik'а из docker-сети. Реальный IP CPA-сети
    лежит в X-Forwarded-For. Берём первый IP (last-write-wins по spec).
    Доверяем only-если есть header — Traefik всегда его выставляет.
    """
    fwd = request.headers.get("x-forwarded-for", "").strip()
    if fwd:
        return fwd.split(",")[0].strip()
    return request.client.host if request.client else "unknown"

_redis_pool: aioredis.Redis | None = None


async def get_redis() -> aioredis.Redis:
    global _redis_pool
    if _redis_pool is None:
        _redis_pool = aioredis.from_url(
            REDIS_URL,
            decode_responses=True,
            max_connections=20,
        )
    return _redis_pool


@asynccontextmanager
async def _lifespan(_app: FastAPI):
    # startup: ничего — Redis-пул создаётся лениво в get_redis().
    yield
    # shutdown: закрываем пул. aclose() — преемник close() в asyncio-клиенте
    # redis-py (close() помечен deprecated). Заменяет снятый в Starlette 1.0
    # @app.on_event("shutdown") — паритетная семантика (выполняется при
    # остановке приложения).
    global _redis_pool
    if _redis_pool is not None:
        await _redis_pool.aclose()
        _redis_pool = None


app = FastAPI(
    title="Webhook Receiver",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
    lifespan=_lifespan,
)


def _not_found() -> PlainTextResponse:
    return PlainTextResponse("404 Not Found", status_code=404)


@app.exception_handler(StarletteHTTPException)
async def _http_exception_handler(request: Request, exc: StarletteHTTPException):
    if exc.status_code == 404:
        return _not_found()
    return PlainTextResponse(exc.detail or "", status_code=exc.status_code)


@app.get("/health")
async def health():
    return PlainTextResponse("ok")


_SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,62}$")


def _is_safe_slug(s: str) -> bool:
    return bool(s and _SLUG_RE.match(s))


# F-S1-008: HMAC-MD5 удалён из whitelist — collision attacks возможны на устаревшем
# алгоритме. SHA1 оставлен на случай легаси CPA-сети, требующей именно его, но
# default и preferred — sha256.
_HMAC_DIGEST_MODS = {
    "hmac-sha256": hashlib.sha256,
    "hmac-sha1": hashlib.sha1,
}


def _verify_signature(
    request: Request,
    body: bytes,
    sig_cfg: dict[str, Any],
) -> bool:
    """
    Опциональная HMAC-проверка хука. Большинство CPA не подписывают —
    тогда sig_cfg.enabled=False и мы возвращаем True (хук валиден после
    проверки secret_path в URL). Для сетей с подписью валидируем заголовок.
    """
    if not sig_cfg.get("enabled"):
        return True

    secret = (sig_cfg.get("secret") or "").encode("utf-8")
    if not secret:
        # Подпись включена, но секрет пуст — конфигурационная ошибка.
        # Возвращаем False, иначе включение фичи без секрета было бы no-op.
        logger.warning("signing enabled but secret is empty for path=%s", request.url.path)
        return False

    digest_mod = _HMAC_DIGEST_MODS.get(sig_cfg.get("algorithm", "hmac-sha256"))
    if digest_mod is None:
        logger.warning("unknown signing algorithm: %r", sig_cfg.get("algorithm"))
        return False

    source = sig_cfg.get("source", "body")
    if source == "body":
        payload = body
    elif source == "query-raw":
        payload = request.url.query.encode("utf-8")
    elif source == "path-and-body":
        payload = request.url.path.encode("utf-8") + body
    else:
        logger.warning("unknown signing source: %r", source)
        return False

    mac = hmac.new(secret, payload, digest_mod)
    fmt = sig_cfg.get("format", "hex")
    if fmt == "hex":
        expected = mac.hexdigest()
    elif fmt == "base64":
        expected = base64.b64encode(mac.digest()).decode("ascii")
    elif fmt == "sha256-prefix-hex":
        # GitHub/Stripe-style: "sha256=<hex>"
        expected = "sha256=" + mac.hexdigest()
    else:
        logger.warning("unknown signing format: %r", fmt)
        return False

    header_name = sig_cfg.get("header", "X-Signature")
    actual = (request.headers.get(header_name, "") or "").strip()
    # Hex case-insensitive (некоторые CPA шлют uppercase). Base64 case-sensitive.
    if fmt in ("hex", "sha256-prefix-hex"):
        actual = actual.lower()
        expected = expected.lower()
    return hmac.compare_digest(expected, actual)


async def _handle_webhook(slug: str, secret: str, request: Request):
    """Main webhook handler."""
    if not _is_safe_slug(slug):
        return _not_found()

    network = get_network(slug)
    if network is None:
        return _not_found()

    if not network.get("is_active", False):
        return _not_found()

    # constant-time сравнение: theoretically prevents remote timing leak,
    # практически — гигиена в security-critical коде.
    if not hmac.compare_digest(network.get("secret_path", "") or "", secret or ""):
        return _not_found()

    # Check allowed HTTP method
    webhook_method = network.get("webhook_method", "")
    if webhook_method and webhook_method != "GET&POST":
        if request.method != webhook_method:
            return PlainTextResponse("method not allowed", status_code=405)

    # Конфиг опциональной HMAC-подписи. Большинство CPA не подписывают —
    # тогда sig_cfg.enabled=False и проверка пропускается.
    sig_cfg = network.get("signing") or {}

    # Если подпись считается с query/path и body не нужен — проверяем сразу.
    # Для source=body отложим проверку до момента, когда тело прочитано.
    if sig_cfg.get("enabled") and sig_cfg.get("source") in ("query-raw", "path-and-body"):
        if sig_cfg.get("source") == "path-and-body" and request.method == "POST":
            pass  # отложим до чтения body
        else:
            if not _verify_signature(request, b"", sig_cfg):
                logger.warning("signature mismatch for slug=%s (source=%s)", slug, sig_cfg.get("source"))
                return _not_found()

    # Reject oversized requests early (declared Content-Length).
    # Не падаем на ValueError, если заголовок битый (например, "0, 7" от прокси).
    content_length_hdr = request.headers.get("content-length", "")
    try:
        cl = int(content_length_hdr) if content_length_hdr else -1
    except ValueError:
        cl = -1
    if cl > MAX_PAYLOAD_BYTES:
        return PlainTextResponse("payload too large", status_code=413)

    # Rate limiting (atomic: INCR + EXPIRE in single Lua script)
    r = await get_redis()

    # F-S1-009 defense-in-depth: per-IP RL до per-slug. Закрывает риск
    # single-attacker flood, выжигающего slug-quota (если он узнал secret).
    ip = _client_ip(request)
    if ip and ip != "unknown":
        ip_key = f"{RATE_LIMIT_IP_PREFIX}{ip}"
        ip_current = await r.eval(_RL_LUA, 1, ip_key)
        if ip_current > RATE_LIMIT_IP_MAX:
            logger.warning("Per-IP rate limit exceeded for ip=%s slug=%s", ip, slug)
            return PlainTextResponse("rate limited", status_code=429)

    rate_limit = int(network.get("rate_limit", 200))
    if rate_limit > 0:
        rl_key = f"{RATE_LIMIT_PREFIX}{slug}"
        current = await r.eval(_RL_LUA, 1, rl_key)
        if current > rate_limit:
            logger.warning("Rate limit exceeded for network %s", slug)
            return PlainTextResponse("rate limited", status_code=429)

    # Extract parameters
    params: dict[str, Any] = {}

    for key, value in request.query_params.items():
        params[key] = value

    if request.method == "POST":
        content_type = request.headers.get("content-type", "")
        # multipart/form-data не поддерживается — реальные CPA шлют JSON или
        # x-www-form-urlencoded. Отвергаем заранее (415), чтобы не тратить
        # rate-limit и память на чтение body, которое всё равно будет отброшено.
        if "multipart/form-data" in content_type:
            logger.warning("multipart/form-data not supported for slug=%s", slug)
            return PlainTextResponse("multipart not supported", status_code=415)

        # Стримим тело с жёстким cap'ом, чтобы Transfer-Encoding: chunked без CL
        # не позволил клиенту прокачать гигабайты в event loop. Парсим из bytes
        # вручную (минуя request.json()/request.form() которые читают unbounded).
        body = b""
        try:
            async for chunk in request.stream():
                body += chunk
                if len(body) > MAX_PAYLOAD_BYTES:
                    return PlainTextResponse("payload too large", status_code=413)
        except Exception:
            return PlainTextResponse("bad body", status_code=400)

        # HMAC-подпись для source=body / path-and-body — проверяем после чтения.
        if sig_cfg.get("enabled") and sig_cfg.get("source") in ("body", "path-and-body"):
            if not _verify_signature(request, body, sig_cfg):
                logger.warning("signature mismatch for slug=%s (source=%s)", slug, sig_cfg.get("source"))
                return _not_found()

        if body:
            try:
                if "application/json" in content_type:
                    parsed = json.loads(body)
                    if isinstance(parsed, dict):
                        params.update(parsed)
                elif "application/x-www-form-urlencoded" in content_type:
                    for k, v in parse_qsl(body.decode("utf-8", errors="replace"),
                                          keep_blank_values=True):
                        params[k] = v
                else:
                    # Без content-type или неизвестный — пробуем JSON, иначе игнор.
                    try:
                        parsed = json.loads(body)
                        if isinstance(parsed, dict):
                            params.update(parsed)
                    except (json.JSONDecodeError, ValueError):
                        pass
            except Exception:
                pass

    if not params:
        return PlainTextResponse("no data", status_code=400)

    message = json.dumps(
        {
            "slug": slug,
            "params": params,
            "received_at": time.time(),
            "ip": request.client.host if request.client else "unknown",
        },
        ensure_ascii=False,
        default=str,
    )

    if len(message.encode("utf-8")) > MAX_PAYLOAD_BYTES:
        logger.warning("Assembled payload exceeds limit for %s", slug)
        return PlainTextResponse("payload too large", status_code=413)

    await r.lpush(QUEUE_KEY, message)

    stats_key = f"webhook:stats:{slug}:{int(time.time()) // 3600}"
    await r.incr(stats_key)
    await r.expire(stats_key, 86400 * 7)

    return PlainTextResponse("ok")


# Both URL patterns
app.add_api_route("/{slug}/{secret}", _handle_webhook, methods=["GET", "POST"], response_class=PlainTextResponse)