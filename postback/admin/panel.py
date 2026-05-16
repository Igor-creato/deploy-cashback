"""
Admin Panel.
Accessible only on 127.0.0.1:8098 (via SSH tunnel).
Provides UI for:
  - Database connection settings
  - Network management (add/edit/delete)
  - Field mapping editor (like Admitad screenshot)
  - Webhook URL generation
  - Recent webhook log viewer
  - Queue stats
"""
import hashlib
import hmac
import json
import logging
import os
import secrets
import time
from typing import Any

import redis
from fastapi import FastAPI, File, Form, Request, Response, UploadFile, Cookie, HTTPException
from fastapi.responses import HTMLResponse, PlainTextResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from starlette.middleware.trustedhost import TrustedHostMiddleware

from app.config import (
    load,
    save,
    generate_secret_path,
    get_db_config,
    get_all_networks,
    network_export_view,
    sanitize_imported_network,
    MAX_IMPORT_BYTES,
    DEFAULT_MAPPING,
    DEFAULT_STATUS_MAP,
    DEFAULT_SIGNING,
)
from app.db import test_connection, get_affiliate_networks, get_recent_webhooks, get_distinct_order_statuses

logger = logging.getLogger("webhook.admin")

ADMIN_SECRET = os.environ.get("ADMIN_SECRET", "")
if not ADMIN_SECRET or ADMIN_SECRET in ("changeme_on_first_run", "123"):
    raise SystemExit("ADMIN_SECRET env var must be set to a strong value (run install.sh to generate)")
REDIS_URL = os.environ.get("REDIS_URL", "redis://localhost:6379/0")
SESSION_COOKIE = "whk_session"
SESSION_TTL = 3600 * 8  # 8 hours

# Привязка session-токена к текущему ADMIN_SECRET. _BOOT_KEY вычисляется
# при импорте, поэтому смена ADMIN_SECRET вступает в силу после рестарта
# контейнера postback. После рестарта старые cookie немедленно отвергаются.
# Сейчас _sessions хранится in-memory и тоже стирается при рестарте — так
# что _BOOT_KEY сегодня даёт защиту-в-резерв на случай миграции на Redis-
# backed sessions, где dict стал бы переживать рестарт.
_BOOT_KEY = hashlib.sha256(("v1:" + ADMIN_SECRET).encode("utf-8")).hexdigest()[:16]

# Whitelist Origin/Referer для CSRF-защиты state-changing методов. Админка
# биндится только на 127.0.0.1:8098 → доступ через SSH-tunnel; всё кроме
# loopback'а — атака через cross-site form POST.
_ALLOWED_ORIGINS = (
    "http://127.0.0.1:8098",
    "http://localhost:8098",
)

# Rate-limit на /login (per-IP). Lua: атомарный INCR + EXPIRE на 60s окно.
# Использует тот же шаблон, что receiver, чтобы избежать race-condition
# между TTL-set и INCR.
_LOGIN_RL_LUA = """
local current = redis.call('INCR', KEYS[1])
if current == 1 then
    redis.call('EXPIRE', KEYS[1], 900)
end
return current
"""
_LOGIN_RL_PREFIX = "admin:rl:login:"
_LOGIN_RL_MAX_FAILS = 10  # 10 попыток за 15 минут per (IP+UA-bucket)


# F-S1-007: per-IP rate-limit бесполезен через SSH-туннель — все запросы
# приходят с client_ip = "127.0.0.1". Расширяем bucket до (IP, UA-hash):
# разные браузеры/CLI получают разные счётчики, что даёт защиту от
# одновременных компрометированных коллизий, не блокируя легитимного
# админа другим клиентом. Pattern совпадает с двухуровневым rate-limit
# плагина (см. memory: feedback_nat_safe_rate_limit, NAT-safe per-IP+UA).
def _client_bucket(request: Request) -> str:
    ip = request.client.host if request.client else "unknown"
    ua = request.headers.get("user-agent", "") or ""
    ua_hash = hashlib.sha256(ua.encode("utf-8")).hexdigest()[:16]
    return f"{ip}:{ua_hash}"


app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)

# Defense-in-depth: даже если 8098 случайно опубликуют наружу, отвергаем
# запросы с не-loopback Host'ом. Starlette сам вырезает порт перед сравнением,
# поэтому в allowed_hosts указываем только имена без портов.
app.add_middleware(
    TrustedHostMiddleware,
    allowed_hosts=["127.0.0.1", "localhost"],
)

templates = Jinja2Templates(directory=os.path.join(os.path.dirname(__file__), "..", "templates"))


def _make_session_token() -> str:
    # Токен = random32:boot_key. Проверка тоже сравнивает boot_key с актуальным
    # _BOOT_KEY → если ADMIN_SECRET сменили, все старые токены инвалидны.
    return secrets.token_hex(32) + ":" + _BOOT_KEY


_sessions: dict[str, float] = {}


def _check_auth(session: str | None) -> bool:
    if not session or ":" not in session:
        return False
    rand_part, _, boot_part = session.rpartition(":")
    if not hmac.compare_digest(boot_part, _BOOT_KEY):
        # ADMIN_SECRET сменили — токен битый.
        _sessions.pop(session, None)
        return False
    expires = _sessions.get(session, 0)
    if expires < time.time():
        _sessions.pop(session, None)
        return False
    return True


def _check_origin(request: Request) -> bool:
    """CSRF-защита для state-changing запросов: разрешаем только Origin/Referer
    с loopback-хостов админки. GET'ы пропускаем — у них нет побочных эффектов.
    Без exemption: даже /login требует Origin/Referer (CLI-клиенты могут явно
    задать `-H 'Origin: http://127.0.0.1:8098'`)."""
    if request.method == "GET":
        return True
    origin = request.headers.get("origin", "")
    referer = request.headers.get("referer", "")
    src = (origin or referer or "").rstrip("/")
    if not src:
        return False
    return any(src.startswith(o) for o in _ALLOWED_ORIGINS)


def _get_redis():
    return redis.from_url(REDIS_URL, decode_responses=True)


def _login_rl_peek(bucket: str) -> int:
    """Текущее число неудачных попыток с bucket'а за окно (без инкремента).

    bucket = "<ip>:<ua_hash>" (см. _client_bucket).
    """
    try:
        r = _get_redis()
        v = r.get(f"{_LOGIN_RL_PREFIX}{bucket}")
        return int(v) if v else 0
    except Exception:
        logger.exception("login rate-limit peek failed")
        return 0


def _login_rl_increment(bucket: str) -> int:
    """Инкрементирует счётчик неудач bucket'а (атомарно с TTL=15min)."""
    try:
        r = _get_redis()
        return int(r.eval(_LOGIN_RL_LUA, 1, f"{_LOGIN_RL_PREFIX}{bucket}"))
    except Exception:
        logger.exception("login rate-limit increment failed")
        return 0


def _get_queue_stats() -> dict[str, Any]:
    try:
        r = _get_redis()
        queue_len = r.llen("webhook:queue")
        dlq_len = r.llen("webhook:dlq")
        return {"queue": queue_len, "dlq": dlq_len}
    except Exception:
        return {"queue": "?", "dlq": "?"}


# --- Auth routes ---


@app.get("/", response_class=HTMLResponse)
async def root(request: Request, whk_session: str | None = Cookie(None)):
    if _check_auth(whk_session):
        return RedirectResponse("/dashboard", status_code=302)
    return templates.TemplateResponse(request, "login.html", {"error": ""})


@app.post("/login")
async def login(request: Request, password: str = Form(...)):
    client_ip = request.client.host if request.client else "unknown"
    bucket = _client_bucket(request)

    # CSRF: /login не проходит через _require_auth, поэтому Origin-check
    # делаем явно. Для CLI без Origin/Referer — отвергаем, чтобы случайный
    # cross-site form-POST с no-referrer/Origin-stripped не мог брутфорсить.
    if not _check_origin(request):
        logger.warning("admin /login origin reject ip=%s origin=%r referer=%r",
                       client_ip,
                       request.headers.get("origin", ""),
                       request.headers.get("referer", ""))
        raise HTTPException(status_code=403, detail="bad origin")

    # Сначала peek счётчик; если уже превышен — отвергаем без проверки пароля.
    fails = _login_rl_peek(bucket)
    if fails >= _LOGIN_RL_MAX_FAILS:
        logger.warning("admin login throttled for bucket=%s (fails=%d)", bucket, fails)
        return PlainTextResponse("too many attempts, retry later", status_code=429)

    if hmac.compare_digest(password, ADMIN_SECRET):
        # Успех — счётчик не инкрементим (легитимные логины не должны блокировать
        # сами себя при многократном входе админа).
        token = _make_session_token()
        _sessions[token] = time.time() + SESSION_TTL
        resp = RedirectResponse("/dashboard", status_code=302)
        # secure=True — на 127.0.0.1 браузер всё равно отдаёт http (исключение
        # spec'а), но при любом случайном reverse-proxy через https это уже работает.
        resp.set_cookie(
            SESSION_COOKIE, token,
            httponly=True, secure=True, samesite="strict",
            max_age=SESSION_TTL, path="/",
        )
        return resp

    # Неудача — инкрементируем счётчик и возвращаем форму.
    new_fails = _login_rl_increment(bucket)
    logger.warning("admin login fail from bucket=%s (fails=%d)", bucket, new_fails)
    return templates.TemplateResponse(request, "login.html", {"error": "Неверный пароль"})


@app.get("/logout")
async def logout(whk_session: str | None = Cookie(None)):
    if whk_session:
        _sessions.pop(whk_session, None)
    resp = RedirectResponse("/", status_code=302)
    resp.delete_cookie(SESSION_COOKIE)
    return resp


# --- Auth middleware check helper ---
def _require_auth(session: str | None, request: Request | None = None):
    if not _check_auth(session):
        raise _RedirectToLogin()
    # CSRF: для всех state-changing методов (POST/PUT/PATCH/DELETE)
    # требуем Origin/Referer с loopback. Cookie-only защиты (samesite=strict)
    # недостаточно — она опирается на корректную работу browser'а;
    # явная проверка origin'а не зависит от клиента.
    if request is not None and not _check_origin(request):
        logger.warning(
            "CSRF/origin reject: path=%s method=%s origin=%r referer=%r",
            request.url.path, request.method,
            request.headers.get("origin", ""),
            request.headers.get("referer", ""),
        )
        raise HTTPException(status_code=403, detail="bad origin")


class _RedirectToLogin(Exception):
    pass


@app.exception_handler(_RedirectToLogin)
async def redirect_to_login(request, exc):
    return RedirectResponse("/", status_code=302)


# --- Dashboard ---


@app.get("/dashboard", response_class=HTMLResponse)
async def dashboard(request: Request, whk_session: str | None = Cookie(None)):
    _require_auth(whk_session, request)
    cfg = load()
    db_ok, db_msg = False, "Не настроено"
    if cfg["db"].get("host"):
        db_ok, db_msg = test_connection()

    networks = get_all_networks()
    stats = _get_queue_stats()

    return templates.TemplateResponse(request, "dashboard.html", {
        "db_ok": db_ok,
        "db_msg": db_msg,
        "db": cfg["db"],
        "networks": networks,
        "stats": stats,
        "network_count": len(networks),
    })


# --- DB Settings ---


@app.get("/db-settings", response_class=HTMLResponse)
async def db_settings_page(request: Request, whk_session: str | None = Cookie(None)):
    _require_auth(whk_session, request)
    cfg = load()
    db_ok, db_msg = False, ""
    if cfg["db"].get("host"):
        db_ok, db_msg = test_connection()
    return templates.TemplateResponse(request, "db_settings.html", {
        "db": cfg["db"], "db_ok": db_ok, "db_msg": db_msg,
    })


@app.post("/db-settings")
async def db_settings_save(
    request: Request,
    whk_session: str | None = Cookie(None),
    host: str = Form(""),
    port: int = Form(3306),
    user: str = Form(""),
    password: str = Form(""),
    database: str = Form(""),
    table_prefix: str = Form("wp_"),
):
    _require_auth(whk_session, request)

    # Sanitize prefix
    import re
    if not re.match(r'^[a-zA-Z0-9_]+$', table_prefix):
        table_prefix = "wp_"

    cfg = load()
    # Keep existing password when the form field is left empty (it is never
    # rendered back to the client to avoid leaking it via view-source).
    new_password = password if password else cfg["db"].get("password", "")
    cfg["db"] = {
        "host": host.strip(),
        "port": port,
        "user": user.strip(),
        "password": new_password,
        "database": database.strip(),
        "table_prefix": table_prefix.strip(),
    }
    save(cfg)

    return RedirectResponse("/db-settings", status_code=302)


@app.post("/db-test")
async def db_test(request: Request, whk_session: str | None = Cookie(None)):
    _require_auth(whk_session, request)
    ok, msg = test_connection()
    return {"ok": ok, "message": msg}


# --- Network Management ---


@app.get("/networks", response_class=HTMLResponse)
async def networks_page(request: Request, whk_session: str | None = Cookie(None)):
    _require_auth(whk_session, request)
    networks = get_all_networks()

    # Try to load from DB
    db_networks = []
    try:
        db_networks = get_affiliate_networks()
    except Exception:
        pass

    return templates.TemplateResponse(request, "networks.html", {
        "networks": networks,
        "db_networks": db_networks,
    })


@app.post("/networks/add")
async def network_add(
    request: Request,
    whk_session: str | None = Cookie(None),
    name: str = Form(""),
    slug: str = Form(""),
):
    _require_auth(whk_session, request)

    import re
    slug = re.sub(r'[^a-z0-9_-]', '', slug.lower().strip())
    name = name.strip()
    if not slug or not name:
        return RedirectResponse("/networks", status_code=302)

    cfg = load()
    if slug not in cfg["networks"]:
        cfg["networks"][slug] = {
            "name": name,
            "slug": slug,
            "secret_path": generate_secret_path(),
            "is_active": True,
            "rate_limit": 200,
            "mapping": dict(DEFAULT_MAPPING),
            "status_mapping": dict(DEFAULT_STATUS_MAP),
            "field_transforms": {},
            "signing": dict(DEFAULT_SIGNING),
        }
        save(cfg)

    return RedirectResponse(f"/networks/{slug}", status_code=302)


@app.post("/networks/import-from-db")
async def network_import(
    request: Request,
    whk_session: str | None = Cookie(None),
    network_id: int = Form(0),
    network_name: str = Form(""),
    network_slug: str = Form(""),
):
    _require_auth(whk_session, request)
    import re
    slug = re.sub(r'[^a-z0-9_-]', '', network_slug.lower().strip())
    name = network_name.strip()
    if not slug or not name:
        return RedirectResponse("/networks", status_code=302)

    cfg = load()
    if slug not in cfg["networks"]:
        cfg["networks"][slug] = {
            "name": name,
            "slug": slug,
            "db_network_id": network_id,
            "secret_path": generate_secret_path(),
            "is_active": True,
            "rate_limit": 200,
            "mapping": dict(DEFAULT_MAPPING),
            "status_mapping": dict(DEFAULT_STATUS_MAP),
            "field_transforms": {},
            "signing": dict(DEFAULT_SIGNING),
        }
        save(cfg)

    return RedirectResponse(f"/networks/{slug}", status_code=302)


@app.get("/networks/{slug}", response_class=HTMLResponse)
async def network_edit_page(slug: str, request: Request, whk_session: str | None = Cookie(None)):
    _require_auth(whk_session, request)
    cfg = load()
    network = cfg["networks"].get(slug)
    if not network:
        return RedirectResponse("/networks", status_code=302)

    # Build webhook URL using configured domain
    webhook_domain = os.environ.get("WEBHOOK_DOMAIN", "")
    if webhook_domain:
        webhook_url = f"https://{webhook_domain}/{slug}/{network.get('secret_path', '')}"
    else:
        webhook_url = f"http://localhost:8099/{slug}/{network.get('secret_path', '')}"

    order_statuses = get_distinct_order_statuses()

    return templates.TemplateResponse(request, "network_edit.html", {
        "network": network,
        "slug": slug,
        "webhook_url": webhook_url,
        "default_mapping": DEFAULT_MAPPING,
        "default_status_map": DEFAULT_STATUS_MAP,
        "order_statuses": order_statuses,
    })


@app.post("/networks/{slug}/save")
async def network_save(slug: str, request: Request, whk_session: str | None = Cookie(None)):
    _require_auth(whk_session, request)
    cfg = load()
    if slug not in cfg["networks"]:
        return RedirectResponse("/networks", status_code=302)

    form = await request.form()

    # Basic fields
    cfg["networks"][slug]["name"] = form.get("name", slug)
    cfg["networks"][slug]["is_active"] = form.get("is_active") == "on"
    webhook_method = form.get("webhook_method", "")
    if webhook_method in ("GET", "POST", "GET&POST"):
        cfg["networks"][slug]["webhook_method"] = webhook_method
    cfg["networks"][slug]["webhook_base_url"] = form.get("webhook_base_url", "")

    try:
        cfg["networks"][slug]["rate_limit"] = max(0, int(form.get("rate_limit", 200)))
    except (ValueError, TypeError):
        cfg["networks"][slug]["rate_limit"] = 200

    # Field mapping
    mapping = {}
    i = 0
    while True:
        field_key = form.get(f"map_field_{i}")
        field_val = form.get(f"map_param_{i}")
        if field_key is None:
            break
        if field_key.strip() and field_val.strip():
            mapping[field_key.strip()] = field_val.strip()
        i += 1

    if mapping:
        cfg["networks"][slug]["mapping"] = mapping

    # Status mapping
    status_map = {}
    j = 0
    while True:
        s_from = form.get(f"status_from_{j}")
        s_to = form.get(f"status_to_{j}")
        if s_from is None:
            break
        if s_from.strip() and s_to.strip():
            status_map[s_from.strip()] = s_to.strip()
        j += 1

    if status_map:
        cfg["networks"][slug]["status_mapping"] = status_map

    # Field transforms
    field_transforms = {}
    k = 0
    while True:
        t_field = form.get(f"transform_field_{k}")
        t_type = form.get(f"transform_type_{k}")
        if t_field is None:
            break
        if t_field.strip() and t_type.strip():
            field_transforms[t_field.strip()] = t_type.strip()
        k += 1
    cfg["networks"][slug]["field_transforms"] = field_transforms

    # Опциональная HMAC-подпись. Существующее значение сохраняется как
    # база (особенно секрет — он не приходит обратно с формы при пустом поле,
    # чтобы не светить через view-source).
    existing_sig = cfg["networks"][slug].get("signing") or dict(DEFAULT_SIGNING)
    sig_secret_form = (form.get("sig_secret") or "").strip()
    sig_algo = (form.get("sig_algorithm") or existing_sig.get("algorithm", "hmac-sha256")).strip()
    sig_format = (form.get("sig_format") or existing_sig.get("format", "hex")).strip()
    sig_source = (form.get("sig_source") or existing_sig.get("source", "body")).strip()
    sig_header = (form.get("sig_header") or existing_sig.get("header", "X-Signature")).strip()

    # Whitelist допустимых значений — защита от инъекции через форму.
    # F-S1-008: HMAC-MD5 удалён (deprecated, collision attacks).
    if sig_algo not in ("hmac-sha256", "hmac-sha1"):
        sig_algo = "hmac-sha256"
    if sig_format not in ("hex", "base64", "sha256-prefix-hex"):
        sig_format = "hex"
    if sig_source not in ("body", "query-raw", "path-and-body"):
        sig_source = "body"
    # Имя HTTP-заголовка: разрешаем буквы/цифры/дефис, ≤64 символа.
    import re as _re
    if not sig_header or not _re.match(r"^[A-Za-z0-9-]{1,64}$", sig_header):
        sig_header = "X-Signature"

    cfg["networks"][slug]["signing"] = {
        "enabled": form.get("sig_enabled") == "on",
        "algorithm": sig_algo,
        "secret": sig_secret_form if sig_secret_form else existing_sig.get("secret", ""),
        "header": sig_header,
        "format": sig_format,
        "source": sig_source,
    }

    save(cfg)
    return RedirectResponse(f"/networks/{slug}", status_code=302)


@app.post("/networks/{slug}/regenerate-path")
async def network_regenerate_path(slug: str, request: Request, whk_session: str | None = Cookie(None)):
    _require_auth(whk_session, request)
    cfg = load()
    if slug in cfg["networks"]:
        cfg["networks"][slug]["secret_path"] = generate_secret_path()
        save(cfg)
    return RedirectResponse(f"/networks/{slug}", status_code=302)


@app.post("/networks/{slug}/toggle")
async def network_toggle(slug: str, request: Request, whk_session: str | None = Cookie(None)):
    _require_auth(whk_session, request)
    cfg = load()
    if slug in cfg["networks"]:
        cfg["networks"][slug]["is_active"] = not cfg["networks"][slug].get("is_active", False)
        save(cfg)
    return RedirectResponse("/networks", status_code=302)


@app.post("/networks/{slug}/delete")
async def network_delete(slug: str, request: Request, whk_session: str | None = Cookie(None)):
    _require_auth(whk_session, request)
    cfg = load()
    cfg["networks"].pop(slug, None)
    save(cfg)
    return RedirectResponse("/networks", status_code=302)


# --- Network settings export / import ---


@app.get("/networks/{slug}/export")
async def network_export(slug: str, request: Request, whk_session: str | None = Cookie(None)):
    """Скачать настройки конкретной сети JSON-файлом (без секретов)."""
    _require_auth(whk_session, request)
    cfg = load()
    network = cfg["networks"].get(slug)
    if not network:
        return RedirectResponse("/networks", status_code=302)

    body = json.dumps(
        network_export_view(slug, network), indent=2, ensure_ascii=False
    )
    import re
    safe_slug = re.sub(r"[^a-z0-9_-]", "", slug.lower()) or "network"
    return Response(
        content=body,
        media_type="application/json",
        headers={
            "Content-Disposition": (
                f'attachment; filename="network-{safe_slug}-settings.json"'
            ),
            "Cache-Control": "no-store",
        },
    )


@app.post("/networks/{slug}/import")
async def network_import_settings(
    slug: str,
    request: Request,
    whk_session: str | None = Cookie(None),
    file: UploadFile = File(...),
):
    """Загрузить настройки сети из JSON-файла. Применяется сразу.

    Серверная валидация (client `accept` не доверяем): расширение/
    content-type, размер ≤ MAX_IMPORT_BYTES, корректный JSON, строгий
    gate _type/_version + whitelist полей. Секреты сохраняются текущими.
    """
    _require_auth(whk_session, request)
    cfg = load()
    if slug not in cfg["networks"]:
        return RedirectResponse("/networks", status_code=302)

    def _reject(reason: str):
        return RedirectResponse(
            f"/networks/{slug}?import_error={reason}", status_code=302
        )

    fname = (file.filename or "").lower()
    ctype = (file.content_type or "").lower()
    if not (fname.endswith(".json") or ctype in ("application/json", "text/json")):
        return _reject("not_json")

    raw = await file.read()
    if len(raw) > MAX_IMPORT_BYTES:
        return _reject("too_large")

    try:
        payload = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return _reject("parse_error")

    clean, err = sanitize_imported_network(payload, cfg["networks"][slug])
    if clean is None:
        return _reject(err or "bad_format")

    cfg["networks"][slug] = clean
    save(cfg)
    return RedirectResponse(f"/networks/{slug}", status_code=302)


# --- Logs ---


@app.get("/logs", response_class=HTMLResponse)
async def logs_page(request: Request, whk_session: str | None = Cookie(None)):
    _require_auth(whk_session, request)
    webhooks = get_recent_webhooks(100)
    stats = _get_queue_stats()
    return templates.TemplateResponse(request, "logs.html", {
        "webhooks": webhooks, "stats": stats,
    })


@app.get("/health")
async def health():
    return PlainTextResponse("ok")
