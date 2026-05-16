"""
Configuration manager.
Stores DB credentials, network configs, and field mappings in a JSON file.
Thread-safe reads/writes with file locking.
"""
import copy
import json
import os
import re
import secrets
import threading
from pathlib import Path
from typing import Any

_lock = threading.Lock()
_CONFIG_PATH = os.environ.get("CONFIG_PATH", "/data/config.json")

_DEFAULT: dict[str, Any] = {
    "db": {
        "host": "",
        "port": 3306,
        "user": "",
        "password": "",
        "database": "",
        "table_prefix": "wp_",
    },
    "networks": {},
}


def _ensure_dir() -> None:
    Path(_CONFIG_PATH).parent.mkdir(parents=True, exist_ok=True)


def load() -> dict[str, Any]:
    with _lock:
        if not os.path.exists(_CONFIG_PATH):
            return json.loads(json.dumps(_DEFAULT))
        with open(_CONFIG_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
    merged = json.loads(json.dumps(_DEFAULT))
    merged.update(data)
    return merged


def save(cfg: dict[str, Any]) -> None:
    _ensure_dir()
    with _lock:
        tmp = _CONFIG_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
        os.replace(tmp, _CONFIG_PATH)


def generate_secret_path() -> str:
    return secrets.token_urlsafe(32)


def get_network(slug: str) -> dict[str, Any] | None:
    cfg = load()
    return cfg["networks"].get(slug)


def get_db_config() -> dict[str, Any]:
    return load()["db"]


def get_all_networks() -> dict[str, Any]:
    return load().get("networks", {})


# ============================================================
# Маппинг полей: {"наше_поле_в_БД": "имя_параметра_в_вебхуке"}
#
# Логика apply_mapping() в processor.py:
#   result["наше_поле"] = params["имя_параметра_в_вебхуке"]
#
# При настройке постбэка в Admitad (Advanced mode) задавайте
# имена параметров (левая колонка) РОВНО такими:
#
#   click_id     = [[[subid1]]]
#   user_id      = [[[subid2]]]
#   uniq_id      = [[[admitad_id]]]
#   order_number = [[[order_id]]]
#   offer_id     = [[[offer_id]]]
#   offer_name   = [[[offer_name]]]
#   order_status = [[[payment_status]]]
#   sum_order    = [[[order_sum]]]
#   comission    = [[[payment_sum]]]
#   currency     = [[[currency]]]
#   action_date  = [[[time]]]
#   click_time   = [[[click_time]]]
#   website_id   = [[[website_id]]]
#   action_type  = [[[type]]]
#
# Тогда маппинг будет identity (левая = правая), и менять его
# не нужно. Если CPA-сеть шлёт параметры под другими именами —
# измените правую часть через админку или в config.json.
# ============================================================

DEFAULT_MAPPING: dict[str, str] = {
    "click_id": "click_id",
    "user_id": "user_id",
    "uniq_id": "uniq_id",
    "order_number": "order_number",
    "offer_id": "offer_id",
    "offer_name": "offer_name",
    "order_status": "order_status",
    "sum_order": "sum_order",
    "comission": "comission",
    "currency": "currency",
    "action_date": "action_date",
    "click_time": "click_time",
    "website_id": "website_id",
    "action_type": "action_type",
}

DEFAULT_STATUS_MAP: dict[str, str] = {
    "approved": "completed",
    "pending": "waiting",
    "declined": "declined",
    "rejected": "declined",
    "open": "waiting",
    "hold": "waiting",
}


# ============================================================
# Опциональная HMAC-подпись хука. По умолчанию выключено —
# большинство CPA-сетей вообще не подписывают свои постбэки.
# Включается per-network через админку для сетей вроде Stripe,
# GitHub, Salesforce, Tinkoff Acquiring и т.п., где есть HMAC.
#
# algorithm: hmac-sha256 (default, preferred) | hmac-sha1 (legacy CPA only)
# header:    имя HTTP-заголовка с подписью (X-Signature, Sign,
#            X-Hub-Signature-256, X-Webhook-Signature, ...)
# format:    hex                — голый hex-digest "a3f2..."
#            base64             — base64-кодированный digest
#            sha256-prefix-hex  — "sha256=a3f2..." (Github/Stripe-style)
# source:    body               — сырое тело запроса (POST, наиболее частый)
#            query-raw          — сырая query-string без "?"
#            path-and-body      — путь URL + body
# ============================================================
DEFAULT_SIGNING: dict[str, Any] = {
    "enabled": False,
    "algorithm": "hmac-sha256",
    "secret": "",
    "header": "X-Signature",
    "format": "hex",
    "source": "body",
}


# ============================================================
# Экспорт / импорт настроек одной сети (админка → JSON-файл).
#
# Решения:
#  - Секреты НЕ выгружаются: secret_path (секретный путь webhook-URL)
#    и signing.secret (HMAC-секрет). При импорте берутся из текущей
#    конфигурации (паттерн как пароль БД в db_settings_save).
#  - Строгий gate по _type/_version + whitelist полей с тип-коэрцией
#    (зеркало network_save в admin/panel.py).
# ============================================================

EXPORT_TYPE = "webhook-receiver-network"
EXPORT_VERSION = 1
MAX_IMPORT_BYTES = 1 * 1024 * 1024  # 1 МиБ — cap на загружаемый файл

_SIG_ALGOS = ("hmac-sha256", "hmac-sha1")
_SIG_FORMATS = ("hex", "base64", "sha256-prefix-hex")
_SIG_SOURCES = ("body", "query-raw", "path-and-body")
_WEBHOOK_METHODS = ("GET", "POST", "GET&POST")
_SIG_HEADER_RE = re.compile(r"^[A-Za-z0-9-]{1,64}$")


def network_export_view(slug: str, network: dict[str, Any]) -> dict[str, Any]:
    """Безопасное представление сети для выгрузки в файл.

    Глубокая копия (исходный cfg не мутируется); удалён secret_path,
    из signing вырезан secret. Обёрнуто в конверт с _type/_version
    для строгой валидации при обратном импорте.
    """
    net = copy.deepcopy(network)
    net.pop("secret_path", None)
    sig = net.get("signing")
    if isinstance(sig, dict):
        sig.pop("secret", None)
    return {
        "_type": EXPORT_TYPE,
        "_version": EXPORT_VERSION,
        "slug": slug,
        "network": net,
    }


def _coerce_str_map(value: Any) -> dict[str, str]:
    """dict с str→str парами; всё нестроковое/невалидное отбрасывается."""
    if not isinstance(value, dict):
        return {}
    out: dict[str, str] = {}
    for k, v in value.items():
        if isinstance(k, str) and isinstance(v, str) and k.strip() and v.strip():
            out[k.strip()] = v.strip()
    return out


def sanitize_imported_network(
    payload: Any, existing: dict[str, Any]
) -> tuple[dict[str, Any] | None, str]:
    """Валидирует загруженный JSON и возвращает чистую конфигурацию сети.

    Returns (clean_network, "") при успехе либо (None, reason) при
    отклонении. Секреты (secret_path, signing.secret, db_network_id)
    всегда берутся из `existing`, а не из файла. Неизвестные ключи
    отбрасываются. Сеть определяется URL-slug'ом — slug из файла
    игнорируется.
    """
    if not isinstance(payload, dict):
        return None, "bad_format"
    # Строгий gate: _type — ровно str, _version — ровно int (не bool,
    # не float). В Python `True == 1` и `1.0 == 1`, поэтому без
    # проверки типа `_version: true|1.0` обошёл бы «строгий» gate.
    if not isinstance(payload.get("_type"), str) or payload["_type"] != EXPORT_TYPE:
        return None, "bad_format"
    ver = payload.get("_version")
    if type(ver) is not int or ver != EXPORT_VERSION:
        return None, "bad_format"
    net = payload.get("network")
    if not isinstance(net, dict):
        return None, "bad_format"

    # Базой служит существующая конфигурация — так гарантированно
    # сохраняются секреты и не теряются служебные поля (slug и т.п.).
    clean = copy.deepcopy(existing)

    if isinstance(net.get("name"), str) and net["name"].strip():
        clean["name"] = net["name"].strip()

    # Только настоящий JSON-bool; иначе сохраняем существующее значение
    # (паритет с network_save: чекбокс == "on"; crafted "false"/0/{} не
    # должны случайно включить отключённую сеть).
    clean["is_active"] = (
        net["is_active"]
        if isinstance(net.get("is_active"), bool)
        else existing.get("is_active", False)
    )

    wm = net.get("webhook_method")
    if wm in _WEBHOOK_METHODS:
        clean["webhook_method"] = wm
    # иначе — сохраняется существующий (или отсутствует)

    if isinstance(net.get("webhook_base_url"), str):
        clean["webhook_base_url"] = net["webhook_base_url"].strip()

    try:
        rl = int(net.get("rate_limit", existing.get("rate_limit", 200)))
        clean["rate_limit"] = rl if rl >= 0 else 200
    except (ValueError, TypeError):
        clean["rate_limit"] = 200

    # Паритет с network_save: mapping/status_mapping перезаписываются
    # только если в файле есть непустой набор; пустой/отсутствующий —
    # сохраняем существующий (минимальный файл не должен стереть всю
    # маршрутизацию). field_transforms network_save выставляет всегда
    # (в т.ч. пустым) — сохраняем это поведение.
    new_mapping = _coerce_str_map(net.get("mapping"))
    if new_mapping:
        clean["mapping"] = new_mapping
    new_status_map = _coerce_str_map(net.get("status_mapping"))
    if new_status_map:
        clean["status_mapping"] = new_status_map
    clean["field_transforms"] = _coerce_str_map(net.get("field_transforms"))

    # signing: whitelist подполей; secret — всегда из existing.
    existing_sig = existing.get("signing") or dict(DEFAULT_SIGNING)
    in_sig = net.get("signing") if isinstance(net.get("signing"), dict) else {}

    algo = in_sig.get("algorithm")
    if algo not in _SIG_ALGOS:
        algo = "hmac-sha256"
    fmt = in_sig.get("format")
    if fmt not in _SIG_FORMATS:
        fmt = "hex"
    src = in_sig.get("source")
    if src not in _SIG_SOURCES:
        src = "body"
    hdr = in_sig.get("header")
    if not isinstance(hdr, str) or not _SIG_HEADER_RE.match(hdr):
        hdr = "X-Signature"

    sig_enabled = (
        in_sig["enabled"]
        if isinstance(in_sig.get("enabled"), bool)
        else bool(existing_sig.get("enabled", False))
    )
    clean["signing"] = {
        "enabled": sig_enabled,
        "algorithm": algo,
        "secret": existing_sig.get("secret", ""),
        "header": hdr,
        "format": fmt,
        "source": src,
    }

    # Секреты/служебные поля — строго из existing (защита от подмены
    # через файл).
    if "secret_path" in existing:
        clean["secret_path"] = existing["secret_path"]
    if "db_network_id" in existing:
        clean["db_network_id"] = existing["db_network_id"]

    return clean, ""