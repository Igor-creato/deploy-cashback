"""
Worker processor.
Consumes webhook messages from Redis queue (BRPOP),
applies field mapping, writes to MySQL.
Runs multiple threads for concurrency.
"""
import datetime
import json
import logging
import os
import signal
import sys
import threading
import time
from typing import Any

import redis
from prometheus_client import Gauge, Counter, start_http_server

from app.config import get_network, get_db_config, DEFAULT_STATUS_MAP
from app.db import (
    save_raw_webhook,
    check_user_exists,
    check_click_id_and_get_user,
    update_webhook_processing_status,
    insert_transaction,
    transaction_exists,
    resolve_partner_token,
    enqueue_notification,
)
from app.email_sender import send_transaction_new

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("webhook.worker")

REDIS_URL = os.environ.get("REDIS_URL", "redis://localhost:6379/0")
QUEUE_KEY = "webhook:queue"
DLQ_KEY = "webhook:dlq"  # dead letter queue
DLQ_MAX_LEN = 9999

# Sanity-floor для unix-timestamp полей webhook payload'а.
# 1577836800 = 2020-01-01 00:00:00 UTC. Защищает от silent-fail при action_date=0:
# раньше epoch=0 проходил `_convert_unix_timestamp` как строка "0", INSERT падал на
# DATETIME, но webhook processing_status уже стоял 'ok' до insert'а (F-S3-04).
# Не ужесточать — CPA-сети шлют refund-постбэки с задержкой 30-60 дней
# (см. plans/sparkling-yawning-lamport.md G7).
MIN_UNIX_TIMESTAMP = 1577836800

# Чувствительные поля webhook payload'а — маскируем перед записью в DLQ,
# т.к. DLQ хранится в Redis и читается через redis-exporter / docker exec.
_DLQ_SENSITIVE_FIELDS = frozenset((
    "user_id", "partner_token", "subid", "subid2", "subid3",
    "click_id", "email", "phone", "ip",
))
CONCURRENCY = int(os.environ.get("WORKER_CONCURRENCY", "4"))
METRICS_PORT = int(os.environ.get("METRICS_PORT", "9100"))
SHUTDOWN = threading.Event()

# Prometheus metrics — scraped by VictoriaMetrics на основном стеке
DLQ_SIZE = Gauge("webhook_dlq_size", "Redis DLQ length")
QUEUE_SIZE = Gauge("webhook_queue_size", "Redis main queue length")
LAST_PROCESSED = Gauge(
    "webhook_last_processed_ts",
    "Unix timestamp последнего успешно обработанного сообщения",
)
PROCESSED_TOTAL = Counter(
    "webhook_processed_total", "Кол-во обработанных сообщений", ["result"]
)


def get_redis_conn() -> redis.Redis:
    return redis.from_url(REDIS_URL, decode_responses=True)


def _sanitize_for_dlq(raw_message: str) -> str:
    """Замаскировать чувствительные поля payload'а перед записью в DLQ.
    Если payload не парсится — возвращаем placeholder без оригинала."""
    try:
        msg = json.loads(raw_message)
    except (json.JSONDecodeError, ValueError):
        return json.dumps({"_dlq_note": "non-json payload dropped",
                           "_size": len(raw_message),
                           "_received_at": time.time()})
    params = msg.get("params") or {}
    if isinstance(params, dict):
        masked: dict[str, Any] = {}
        for k, v in params.items():
            if k.lower() in _DLQ_SENSITIVE_FIELDS:
                masked[k] = "***"
            else:
                masked[k] = v
        msg["params"] = masked
    return json.dumps(msg, ensure_ascii=False, default=str)


def apply_mapping(params: dict[str, Any], mapping: dict[str, str]) -> dict[str, Any]:
    """
    Transform incoming params using network mapping.
    mapping: {"our_field": "network_param_name"}
    Example: {"user_id": "subid2"} means params["subid2"] -> result["user_id"]
    """
    result: dict[str, Any] = {}
    for our_field, network_param in mapping.items():
        value = params.get(network_param, "")
        if value is None:
            value = ""
        result[our_field] = value
    return result


def resolve_status(raw_status: str, network_status_map: dict[str, str] | None) -> str:
    """Map network-specific status to our enum."""
    status_map = network_status_map or DEFAULT_STATUS_MAP
    raw_lower = str(raw_status).lower().strip()
    return status_map.get(raw_lower, "waiting")


def _convert_unix_timestamp(value: Any) -> str:
    """Convert Unix timestamp (seconds since epoch) to MySQL DATETIME string."""
    try:
        ts = float(value)
        # Valid range: 2000-01-01 to 2100-01-01
        if ts < 946684800 or ts > 4102444800:
            return str(value)
        dt = datetime.datetime.fromtimestamp(ts, tz=datetime.timezone.utc)
        return dt.strftime("%Y-%m-%d %H:%M:%S")
    except (ValueError, TypeError, OSError):
        return str(value)


def apply_field_transforms(
    data: dict[str, Any], transforms: dict[str, str]
) -> dict[str, Any]:
    """
    Apply value transformations to mapped fields.
    transforms: {"field_name": "transform_type"}
    """
    if not transforms:
        return data

    result = dict(data)
    for field, transform_type in transforms.items():
        value = result.get(field, "")
        if not value:
            continue
        if transform_type == "unix_timestamp":
            result[field] = _convert_unix_timestamp(value)
    return result


def _validate_unix_timestamp_fields(
    data: dict[str, Any],
    transforms: dict[str, str] | None,
    *,
    min_timestamp: int = MIN_UNIX_TIMESTAMP,
) -> str | None:
    """
    Sanity-валидация unix_timestamp полей mapped-payload'а.

    Возвращает имя первого invalid поля или None если всё OK.
    Pass-through:
      - отсутствующее/пустое значение (caller отвечает за required-field check),
      - не-числовое значение (трактуем как уже отформатированный datetime —
        downstream INSERT отбьёт если формат битый).

    Reject:
      - числовое значение < min_timestamp (битый payload, action_date=0 и т.п.).
    """
    if not transforms:
        return None
    for field, transform_type in transforms.items():
        if transform_type != "unix_timestamp":
            continue
        value = data.get(field)
        if value is None or value == "":
            continue
        try:
            ts = float(value)
        except (TypeError, ValueError):
            continue
        if ts < min_timestamp:
            return field
    return None


def _push_validation_failure_to_dlq(raw_message: str, reason: str) -> None:
    """Best-effort lpush to DLQ с annotation `_dlq_error=<reason>`.

    Acquires свою redis-conn (validation-failures редкие, перф некритичен).
    Никогда не raise — DLQ telemetry не должна ронять основной flow.
    """
    sanitized = _sanitize_for_dlq(raw_message)
    try:
        payload = json.loads(sanitized)
        if isinstance(payload, dict):
            payload["_dlq_error"] = reason
            sanitized = json.dumps(payload, ensure_ascii=False, default=str)
    except (ValueError, json.JSONDecodeError):
        pass
    try:
        r = get_redis_conn()
        r.lpush(DLQ_KEY, sanitized)
        r.ltrim(DLQ_KEY, 0, DLQ_MAX_LEN)
    except Exception:
        logger.exception("DLQ push failed for validation reason=%s", reason)


def process_message(raw_message: str) -> None:
    """Process a single webhook message."""
    try:
        msg = json.loads(raw_message)
    except json.JSONDecodeError:
        # Do not log the message body — it may contain user identifiers / partner tokens.
        logger.error("Invalid JSON in queue (size=%d bytes)", len(raw_message))
        return

    slug = msg.get("slug", "")
    params = msg.get("params", {})
    received_at = msg.get("received_at", time.time())

    # Load network config
    network = get_network(slug)
    if network is None:
        logger.warning("Unknown network slug in queue: %s", slug)
        return

    mapping = network.get("mapping", {})
    status_mapping = network.get("status_mapping")

    # 1. Save raw webhook to cashback_webhooks
    payload_json = json.dumps(params, ensure_ascii=False, default=str)
    webhook_id = save_raw_webhook(payload_json, slug)
    if webhook_id is None:
        logger.info("Duplicate webhook for %s, skipping", slug)
        return

    # 2. Apply field mapping
    mapped = apply_mapping(params, mapping)

    # 2b. Sanity-валидация unix_timestamp полей ДО transforms.
    # Без этой проверки action_date=0 silently проходил через
    # `_convert_unix_timestamp` как строка "0", INSERT падал на DATETIME, но
    # webhook processing_status уже был установлен 'ok' до insert'а — деньги
    # пропадали без алерта (F-S3-04). Маршрутизируем в DLQ для ручного разбора.
    field_transforms = network.get("field_transforms", {})
    invalid_field = _validate_unix_timestamp_fields(mapped, field_transforms)
    if invalid_field is not None:
        update_webhook_processing_status(webhook_id, "error")
        logger.warning(
            "Webhook validation failed: %s=%r below MIN_UNIX_TIMESTAMP (%d), "
            "webhook_id=%s slug=%s",
            invalid_field, mapped.get(invalid_field), MIN_UNIX_TIMESTAMP,
            webhook_id, slug,
        )
        PROCESSED_TOTAL.labels(result="validation_error").inc()
        _push_validation_failure_to_dlq(
            raw_message, f"unix_timestamp_below_min:{invalid_field}"
        )
        return

    # 2c. Apply field transforms (e.g. Unix timestamp -> datetime)
    mapped = apply_field_transforms(mapped, field_transforms)

    # 3. Resolve order status
    raw_status = mapped.get("order_status", "waiting")
    mapped["order_status"] = resolve_status(raw_status, status_mapping)

    # 4. Set partner_name from network config
    mapped["partner_name"] = network.get("name", slug)

    click_id = mapped.get("click_id", "")
    uniq_id = str(mapped.get("uniq_id", ""))

    # 4b. If transaction already exists for this click_id — skip, let API cron handle updates.
    if click_id and transaction_exists(click_id):
        update_webhook_processing_status(webhook_id, "ok")
        logger.info(
            "Webhook for existing transaction %s/%s, skipping update (handled by API cron)",
            mapped["partner_name"], uniq_id,
        )
        return

    # 5. Click-ID security validation (only reached for new transactions).
    # All new transactions must have a click_id present in cashback_click_log.
    # No FK — click_log is cleaned every 90 days; this is a point-in-time check.
    if not click_id:
        update_webhook_processing_status(webhook_id, "click_not_found")
        logger.warning(
            "No click_id in postback for %s, webhook_id=%s — transaction not created",
            slug, webhook_id,
        )
        return

    cl_exists, log_user_id = check_click_id_and_get_user(click_id)

    if not cl_exists:
        update_webhook_processing_status(webhook_id, "click_not_found")
        logger.warning(
            "click_id not found in click_log for %s, webhook_id=%s, click_id=%s",
            slug, webhook_id, click_id,
        )
        return

    # click_id found — verify user_id match.
    # Postback user_id may be: numeric "5", partner_token "28732ae1...", "unregistered", or "".
    user_id_raw = str(mapped.get("user_id", "") or "").strip()

    # Resolve partner_token → numeric user_id (new format since partner_token migration)
    resolved_from_token = False
    if user_id_raw and not user_id_raw.isdigit() and user_id_raw.lower() != "unregistered":
        resolved_user_id = resolve_partner_token(user_id_raw)
        if resolved_user_id is not None:
            postback_user_id = resolved_user_id
            resolved_from_token = True
        else:
            postback_user_id = 0  # unknown token → treat as unregistered
    else:
        try:
            postback_user_id = int(user_id_raw) if user_id_raw and user_id_raw.isdigit() else 0
        except (ValueError, TypeError):
            postback_user_id = 0

    if postback_user_id != log_user_id:
        update_webhook_processing_status(webhook_id, "user_mismatch")
        # Mask raw user_id — when it is a partner_token (~32 hex chars) it can identify the user.
        raw_masked = user_id_raw if user_id_raw.isdigit() or user_id_raw == "" else f"{user_id_raw[:4]}***"
        logger.warning(
            "user_id mismatch: click_log=%s, postback=%s (raw=%s), click_id=%s, webhook_id=%s",
            log_user_id, postback_user_id, raw_masked, click_id, webhook_id,
        )
        return  # Do not insert — suspicious click fraud indicator
    else:
        update_webhook_processing_status(webhook_id, "ok")

    # 6. Validate required fields
    if not uniq_id:
        logger.warning("No uniq_id in webhook for %s, webhook_id=%s", slug, webhook_id)
        return

    # 7. Set resolved numeric user_id (partner_token already resolved above)
    user_id = postback_user_id
    mapped["user_id"] = user_id if user_id > 0 else user_id_raw

    # 9. Check if user is registered
    registered = False
    if user_id > 0:
        try:
            registered = check_user_exists(user_id)
        except Exception:
            registered = False

    # 10. Insert transaction
    ok, reason, insert_id = insert_transaction(mapped, registered)
    if ok:
        target = "cashback_transactions" if registered else "cashback_unregistered_transactions"
        # Не светим numeric user_id в info-логе: иначе docker logs webhook-worker
        # построит таблицу user_id ↔ partner ↔ purchase history. user_id всё равно
        # доступен через webhook_id ↔ cashback_transactions для админа в БД.
        logger.info(
            "Inserted into %s: webhook=%s, uniq=%s, partner=%s, status=%s",
            target, webhook_id, uniq_id, mapped["partner_name"], mapped["order_status"],
        )

        # Email notification for registered users
        if registered and user_id > 0 and insert_id > 0:
            # Direct SMTP — immediate, no WordPress dependency
            email_sent = send_transaction_new(
                user_id=user_id,
                partner=mapped.get("partner_name", ""),
                offer_name=mapped.get("offer_name", ""),
                sum_order=mapped.get("sum_order", 0),
                order_status=mapped["order_status"],
            )
            # Enqueue for audit; if SMTP sent — mark processed to avoid duplicate
            enqueue_notification(
                event_type="transaction_new",
                transaction_id=insert_id,
                user_id=user_id,
                new_status=mapped["order_status"],
                already_sent=email_sent,
            )
    elif reason == "duplicate":
        logger.debug("Duplicate transaction, no changes: %s/%s", mapped["partner_name"], uniq_id)
    else:
        logger.error("Failed to insert: %s", reason)


def worker_loop(worker_id: int) -> None:
    """Single worker thread loop."""
    logger.info("Worker-%d started", worker_id)
    r = get_redis_conn()

    while not SHUTDOWN.is_set():
        try:
            # BRPOP blocks for 2 seconds max, then loops to check shutdown
            result = r.brpop(QUEUE_KEY, timeout=2)
            if result is None:
                continue

            _, raw_message = result
            try:
                process_message(raw_message)
                LAST_PROCESSED.set(time.time())
                PROCESSED_TOTAL.labels(result="ok").inc()
            except Exception:
                logger.exception("Error processing message")
                PROCESSED_TOTAL.labels(result="error").inc()
                # Push to dead letter queue (sanitized — без user_id/partner_token).
                # lpush + ltrim 0..DLQ_MAX_LEN: новые сообщения в head, обрезаются хвостом.
                try:
                    r.lpush(DLQ_KEY, _sanitize_for_dlq(raw_message))
                    r.ltrim(DLQ_KEY, 0, DLQ_MAX_LEN)
                except Exception:
                    pass

        except redis.ConnectionError:
            logger.error("Redis connection lost, reconnecting in 5s...")
            time.sleep(5)
            try:
                r = get_redis_conn()
            except Exception:
                pass
        except Exception:
            logger.exception("Unexpected error in worker loop")
            time.sleep(1)

    logger.info("Worker-%d stopped", worker_id)


def handle_signal(signum, frame):
    logger.info("Received signal %s, shutting down...", signum)
    SHUTDOWN.set()


def metrics_updater_loop() -> None:
    """Каждые 30 секунд обновляет gauge размеров очередей Redis."""
    r = get_redis_conn()
    while not SHUTDOWN.is_set():
        try:
            DLQ_SIZE.set(r.llen(DLQ_KEY))
            QUEUE_SIZE.set(r.llen(QUEUE_KEY))
        except redis.ConnectionError:
            try:
                r = get_redis_conn()
            except Exception:
                pass
        except Exception:
            logger.exception("metrics updater error")
        SHUTDOWN.wait(30)


def main():
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    # Стартуем экспозицию /metrics ПЕРЕД consumer-потоками,
    # чтобы Grafana алерт webhook-stale не паниковал в момент рестарта.
    LAST_PROCESSED.set(time.time())
    start_http_server(METRICS_PORT)
    logger.info("Prometheus metrics on :%d/metrics", METRICS_PORT)

    # Wait for DB config
    logger.info("Starting worker with %d threads", CONCURRENCY)

    db_cfg = get_db_config()
    if not db_cfg.get("host"):
        logger.warning("Database not configured yet. Worker will retry when messages arrive.")

    threads = []
    for i in range(CONCURRENCY):
        t = threading.Thread(target=worker_loop, args=(i,), daemon=True)
        t.start()
        threads.append(t)

    # Background-поток обновляет метрики DLQ/QUEUE
    metrics_t = threading.Thread(target=metrics_updater_loop, daemon=True)
    metrics_t.start()
    threads.append(metrics_t)

    # Wait for shutdown
    while not SHUTDOWN.is_set():
        time.sleep(1)

    # Wait for threads
    for t in threads:
        t.join(timeout=10)

    logger.info("All workers stopped")


if __name__ == "__main__":
    main()
