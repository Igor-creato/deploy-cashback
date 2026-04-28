"""
Email sender for webhook worker.
Sends transaction notifications directly via SMTP,
independent of WordPress / WP Cron.

Sender name/email are read from WordPress settings (wp_options):
  - cashback_email_sender_name  (fallback: blogname)
  - cashback_email_sender_email (fallback: admin_email)

Brand color, logo and signature also mirror WP-plugin sources
(class-cashback-theme-color.php + class-cashback-email-sender.php),
so emails sent from this service look identical to those sent
through wp_mail() by the plugin.

Site URL is built from DOMAIN env var (shared .env).
"""
import hashlib
import html as _html_lib
import logging
import os
import re
import smtplib
import time
from email.header import Header
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.utils import formataddr
from typing import Any

import phpserialize

from app.db import get_conn

logger = logging.getLogger("webhook.email")

# SMTP configuration from environment (shared .env)
SMTP_HOST = os.environ.get("SMTP_HOST", "")
SMTP_PORT = int(os.environ.get("SMTP_PORT", "465"))
SMTP_USER = os.environ.get("SMTP_USER", "")


def _read_smtp_password() -> str:
    pw = os.environ.get("SMTP_PASSWORD", "")
    if pw:
        return pw
    pw_file = os.environ.get("SMTP_PASSWORD_FILE", "")
    if pw_file:
        try:
            with open(pw_file, "r", encoding="utf-8") as f:
                return f.read().strip()
        except OSError:
            logger.warning("SMTP_PASSWORD_FILE задан, но не читается: %s", pw_file)
    return ""


SMTP_PASSWORD = _read_smtp_password()
# SMTP_SECURE=ssl → port 465 implicit SSL; SMTP_SECURE=tls → port 587 STARTTLS
SMTP_SECURE = os.environ.get("SMTP_SECURE", "ssl").lower()

# Domain from shared .env (e.g. "site.automatization-bot.ru")
DOMAIN = os.environ.get("DOMAIN", "")


def is_configured() -> bool:
    """Check if SMTP is configured."""
    return bool(SMTP_HOST)


def _get_site_url() -> str:
    """Build site URL from DOMAIN env var."""
    if DOMAIN:
        return f"https://{DOMAIN.strip('/')}"
    return ""


# =====================================================================
# WordPress settings cache (from wp_options)
# =====================================================================

_wp_settings_cache: dict[str, str] = {}
_wp_settings_ts: float = 0.0
_WP_CACHE_TTL = 300  # 5 minutes


def _get_wp_option(option_name: str) -> str | None:
    """Read a single option from wp_options."""
    from app.db import _prefix
    prefix = _prefix()
    try:
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    f"SELECT `option_value` FROM `{prefix}options` "
                    f"WHERE `option_name` = %s LIMIT 1",
                    (option_name,),
                )
                row = cur.fetchone()
                if row is not None:
                    return row.get("option_value", "")
                return None
    except Exception:
        logger.exception("Failed to read wp_option %s", option_name)
        return None


def _get_sender_settings() -> tuple[str, str]:
    """
    Get sender name and email from WordPress settings.
    Priority matches Cashback_Email_Sender in PHP:
      name:  cashback_email_sender_name → blogname → 'Cashback'
      email: cashback_email_sender_email → admin_email → SMTP_USER
    Cached for 5 minutes.
    """
    import time
    global _wp_settings_cache, _wp_settings_ts

    now = time.time()
    if _wp_settings_cache and (now - _wp_settings_ts) < _WP_CACHE_TTL:
        return _wp_settings_cache.get("from_name", "Cashback"), _wp_settings_cache.get("from_email", "")

    # Read from DB
    sender_name = _get_wp_option("cashback_email_sender_name") or ""
    if not sender_name:
        sender_name = _get_wp_option("blogname") or "Cashback"

    sender_email = _get_wp_option("cashback_email_sender_email") or ""
    if not sender_email:
        sender_email = _get_wp_option("admin_email") or ""
    if not sender_email:
        sender_email = os.environ.get("SMTP_FROM") or os.environ.get("SMTP_FROM_EMAIL") or SMTP_USER or ""

    _wp_settings_cache = {"from_name": sender_name, "from_email": sender_email}
    _wp_settings_ts = now

    return sender_name, sender_email


# =====================================================================
# User data
# =====================================================================

def _get_user_email(user_id: int) -> tuple[str, str] | None:
    """
    Get user email and display_name from wp_users.
    Returns (email, display_name) or None.
    """
    from app.db import _prefix
    prefix = _prefix()
    table = f"{prefix}users"
    try:
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    f"SELECT `user_email`, `display_name` FROM `{table}` "
                    f"WHERE `ID` = %s LIMIT 1",
                    (user_id,),
                )
                row = cur.fetchone()
                if row and row.get("user_email"):
                    return row["user_email"], row.get("display_name") or ""
                return None
    except Exception:
        logger.exception("Failed to get user email for user_id=%s", user_id)
        return None


def _is_notification_enabled(user_id: int, notification_type: str) -> bool:
    """
    Check if notification is enabled for this user.
    Checks both global setting (wp_options) and user preference.
    Returns True if enabled (default when no preference exists).
    """
    from app.db import _prefix
    prefix = _prefix()
    try:
        with get_conn() as conn:
            with conn.cursor() as cur:
                # Check global setting: wp_options → cashback_notify_{type}
                cur.execute(
                    f"SELECT `option_value` FROM `{prefix}options` "
                    f"WHERE `option_name` = %s LIMIT 1",
                    (f"cashback_notify_{notification_type}",),
                )
                row = cur.fetchone()
                if row is not None:
                    val = row.get("option_value", "")
                    if val == "0":
                        return False

                # Check user preference
                cur.execute(
                    f"SELECT `enabled` FROM `{prefix}cashback_notification_preferences` "
                    f"WHERE `user_id` = %s AND `notification_type` = %s LIMIT 1",
                    (user_id, notification_type),
                )
                row = cur.fetchone()
                if row is not None:
                    return bool(int(row.get("enabled", 1)))

                return True
    except Exception:
        logger.exception("Failed to check notification preference for user_id=%s", user_id)
        return True


# =====================================================================
# Branding (brand color, logo, signature) — mirrors WP plugin
# Sources: includes/class-cashback-theme-color.php
#          notifications/class-cashback-email-sender.php (get_logo_url)
# =====================================================================

_BRAND_FALLBACK_COLOR = "#2271b1"
_HEX_RE = re.compile(r"^#[0-9a-fA-F]{6}$")
_BRANDING_CACHE_TTL = 300  # 5 minutes
_branding_cache: dict[str, Any] = {}
_branding_cache_ts: float = 0.0


_PHP_UNSER_MAX_BYTES = 64 * 1024


def _php_unserialize(value: Any) -> Any:
    """
    Safely PHP-unserialize a wp_options value. Returns the decoded value or
    None on any error (broken data must not break email rendering).

    Размер ограничен _PHP_UNSER_MAX_BYTES: phpserialize.loads — pure-Python
    рекурсивный парсер, не имеет recursion-/size-guard'а. Глубоко-вложенный
    blob из скомпрометированного wp_options крашит worker через RecursionError
    или раздувает память. WP options обычно <10 KB, 64 KB — щедрый лимит.
    """
    if not value:
        return None
    if isinstance(value, str):
        data = value.encode("utf-8", errors="replace")
    elif isinstance(value, (bytes, bytearray)):
        data = bytes(value)
    else:
        return None
    if len(data) > _PHP_UNSER_MAX_BYTES:
        logger.warning("Refusing to unserialize wp_option of size %d (limit %d)",
                       len(data), _PHP_UNSER_MAX_BYTES)
        return None
    try:
        return phpserialize.loads(data, decode_strings=True)
    except Exception:  # pylint: disable=broad-except
        return None


def _normalize_hex(value: Any) -> str | None:
    """
    Normalize a color value to '#RRGGBB' or return None.
    Supports Woodmart array form {'idle': '#hex'} and plain strings.
    """
    if isinstance(value, dict):
        value = value.get("idle", "")
    if not isinstance(value, str):
        return None
    value = value.strip()
    if value == "":
        return None
    if _HEX_RE.match(value):
        return value
    return None


def _get_active_stylesheet() -> str:
    """Return active theme directory slug (wp_options.stylesheet)."""
    return _get_wp_option("stylesheet") or ""


def _get_theme_mods(stylesheet: str) -> dict[str, Any]:
    """Read theme_mods_<stylesheet> as a dict (PHP-serialized)."""
    if not stylesheet:
        return {}
    raw = _get_wp_option(f"theme_mods_{stylesheet}")
    decoded = _php_unserialize(raw)
    if isinstance(decoded, dict):
        return decoded
    return {}


def _get_brand_color() -> str:
    """
    Brand color resolution chain (mirrors Cashback_Theme_Color::get_brand_color):
      1) wp_options.xts-woodmart-options['primary-color']
      2) theme_mods_<stylesheet>['primary-color']
      3) fallback #2271b1
    """
    # Woodmart options
    woodmart = _php_unserialize(_get_wp_option("xts-woodmart-options"))
    if isinstance(woodmart, dict) and "primary-color" in woodmart:
        hx = _normalize_hex(woodmart["primary-color"])
        if hx:
            return hx

    # Standard Customizer API
    mods = _get_theme_mods(_get_active_stylesheet())
    if "primary-color" in mods:
        hx = _normalize_hex(mods["primary-color"])
        if hx:
            return hx

    return _BRAND_FALLBACK_COLOR


def _get_contrast_text_color(hex_color: str) -> str:
    """
    Pick readable text color (#ffffff or #1a1a1a) for the given background.
    Uses luma threshold 170 to match Cashback_Theme_Color::get_contrast_text_color
    (mid-bright brand colors like Woodmart green #83b735, luma≈152, get white text).
    """
    h = hex_color.lstrip("#")
    if len(h) != 6:
        return "#ffffff"
    try:
        r = int(h[0:2], 16)
        g = int(h[2:4], 16)
        b = int(h[4:6], 16)
    except ValueError:
        return "#ffffff"
    luma = 0.299 * r + 0.587 * g + 0.114 * b
    return "#1a1a1a" if luma >= 170 else "#ffffff"


def _get_signature() -> str:
    """Email signature appended after the body (wp_options.cashback_email_signature)."""
    return _get_wp_option("cashback_email_signature") or ""


def _attachment_guid(attachment_id: int) -> str | None:
    """Return wp_posts.guid for an attachment id, or None."""
    if attachment_id <= 0:
        return None
    from app.db import _prefix
    prefix = _prefix()
    try:
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    f"SELECT `guid` FROM `{prefix}posts` "
                    f"WHERE `ID` = %s AND `post_type` = 'attachment' LIMIT 1",
                    (attachment_id,),
                )
                row = cur.fetchone()
                if row and row.get("guid"):
                    return str(row["guid"])
    except Exception:  # pylint: disable=broad-except
        logger.exception("Failed to read attachment guid id=%s", attachment_id)
    return None


def _find_logo_image_in_elements(elements: Any) -> dict[str, Any] | None:
    """
    Recursively walk Woodmart Header Builder elements tree looking for an
    element with params.image. Mirrors find_logo_image_in_elements() in PHP.
    """
    if not isinstance(elements, (list, dict)):
        return None
    iterable = elements.values() if isinstance(elements, dict) else elements
    for element in iterable:
        if not isinstance(element, dict):
            continue
        params = element.get("params")
        if isinstance(params, dict):
            image = params.get("image")
            if isinstance(image, dict) and (image.get("url") or image.get("id")):
                return image
        for nested_key in ("elements", "columns", "rows", "children"):
            nested = element.get(nested_key)
            if nested:
                found = _find_logo_image_in_elements(nested)
                if found is not None:
                    return found
    return None


def _get_woodmart_logo_url() -> str | None:
    """Mirror of Cashback_Email_Sender::get_woodmart_logo_url()."""
    header_id = _get_wp_option("whb_main_header")
    if not header_id:
        return None
    header_data = _php_unserialize(_get_wp_option(f"whb_{header_id}"))
    if not isinstance(header_data, dict):
        return None
    elements = header_data.get("elements")
    if not elements:
        return None
    image = _find_logo_image_in_elements(elements)
    if image is None:
        return None
    url = image.get("url")
    if isinstance(url, str) and url:
        return url
    image_id = image.get("id")
    try:
        image_id_int = int(image_id) if image_id is not None else 0
    except (ValueError, TypeError):
        image_id_int = 0
    return _attachment_guid(image_id_int)


def _get_logo_url() -> str | None:
    """
    Logo URL resolution chain (mirrors Cashback_Email_Sender::get_logo_url):
      1) Woodmart Header Builder image
      2) theme_mods.custom_logo (attachment ID → guid)
      3) theme_mods.site_icon (attachment ID → guid)
      4) None — header is rendered without <img>
    """
    woodmart_logo = _get_woodmart_logo_url()
    if woodmart_logo:
        return woodmart_logo

    mods = _get_theme_mods(_get_active_stylesheet())

    custom_logo = mods.get("custom_logo")
    try:
        custom_logo_id = int(custom_logo) if custom_logo is not None else 0
    except (ValueError, TypeError):
        custom_logo_id = 0
    if custom_logo_id > 0:
        url = _attachment_guid(custom_logo_id)
        if url:
            return url

    site_icon = mods.get("site_icon")
    try:
        site_icon_id = int(site_icon) if site_icon is not None else 0
    except (ValueError, TypeError):
        site_icon_id = 0
    if site_icon_id > 0:
        url = _attachment_guid(site_icon_id)
        if url:
            return url

    return None


def _get_branding() -> dict[str, Any]:
    """
    Cached branding bundle (5 min TTL). Reading wp_options on every email
    is cheap, but this also bounds the impact of broken serialized data.
    """
    global _branding_cache, _branding_cache_ts
    now = time.time()
    if _branding_cache and (now - _branding_cache_ts) < _BRANDING_CACHE_TTL:
        return _branding_cache
    brand_color = _get_brand_color()
    branding = {
        "brand_color": brand_color,
        "text_color": _get_contrast_text_color(brand_color),
        "logo_url": _get_logo_url(),
        "signature": _get_signature(),
    }
    _branding_cache = branding
    _branding_cache_ts = now
    return branding


# =====================================================================
# HTML template
# =====================================================================

def _render_html(subject: str, body_text: str, site_name: str, user_id: int | None = None) -> str:
    """
    Render HTML email template — mirrors Cashback_Email_Sender::render_html_template().
    Brand color / logo / signature come from WordPress settings, so emails
    sent from this service match those sent through wp_mail() by the plugin.
    """
    site_url = _get_site_url() or "#"
    branding = _get_branding()
    brand_color = branding["brand_color"]
    text_color = branding["text_color"]
    logo_url = branding["logo_url"]
    signature = branding["signature"]

    settings_link = ""
    if user_id and _get_site_url():
        settings_link = f"{_get_site_url()}/my-account/cashback-notifications/"

    parts: list[str] = [
        '<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1.0">',
        f'<title>{_esc(subject)}</title></head>',
        '<body style="margin:0;padding:0;background:#f4f4f7;font-family:Arial,Helvetica,sans-serif;">',
        '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f7;">',
        '<tr><td align="center" style="padding:24px 16px;">',
        '<table role="presentation" width="600" cellpadding="0" cellspacing="0" '
        'style="background:#ffffff;border-radius:8px;overflow:hidden;max-width:600px;width:100%;">',
        # Header
        f'<tr><td style="background:{_esc(brand_color)};padding:20px 32px;">',
        '<table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>',
    ]

    if logo_url:
        parts.append('<td style="padding-right:12px;vertical-align:middle;">')
        parts.append(f'<a href="{_esc(site_url)}" style="text-decoration:none;display:inline-block;">')
        parts.append(
            f'<img src="{_esc(logo_url)}" height="40" alt="{_esc(site_name)}" '
            'style="display:block;border:0;max-height:40px;width:auto;">'
        )
        parts.append('</a></td>')

    parts.append('<td style="vertical-align:middle;">')
    parts.append(
        f'<a href="{_esc(site_url)}" style="color:{_esc(text_color)};'
        'text-decoration:none;font-size:20px;font-weight:bold;">'
    )
    parts.append(f'{_esc(site_name)}</a></td>')
    parts.append('</tr></table></td></tr>')

    # Body
    parts.append('<tr><td style="padding:32px;color:#333333;font-size:15px;line-height:1.6;">')
    parts.append(f'<p style="white-space:pre-line;margin:0 0 16px;">{_esc(body_text)}</p>')

    if signature:
        parts.append(
            '<p style="white-space:pre-line;margin:24px 0 0;color:#555555;font-size:14px;">'
        )
        parts.append(_nl2br(_esc(signature)))
        parts.append('</p>')

    parts.append('</td></tr>')

    # Footer
    parts.append('<tr><td style="padding:16px 32px;border-top:1px solid #eee;color:#999999;font-size:12px;">')
    parts.append('<p style="margin:0 0 8px;">Это автоматическое сообщение, не отвечайте на него.</p>')

    if settings_link:
        parts.append('<p style="margin:0;">')
        parts.append(
            f'<a href="{_esc(settings_link)}" style="color:{_esc(brand_color)};text-decoration:underline;">'
            'Настроить уведомления</a></p>'
        )

    parts.append('</td></tr></table></td></tr></table></body></html>')
    return "".join(parts)


def _esc(s: str) -> str:
    """Minimal HTML escaping (matches PHP esc_html / esc_attr / esc_url for our usage)."""
    return _html_lib.escape(s, quote=True)


def _nl2br(s: str) -> str:
    """Mirror PHP nl2br: insert <br /> before each newline (text already escaped)."""
    return s.replace("\r\n", "\n").replace("\r", "\n").replace("\n", "<br />\n")


# =====================================================================
# SMTP send
# =====================================================================

def _send_email(to: str, subject: str, html: str, from_name: str, from_email: str) -> bool:
    """Send email via SMTP. Supports SSL (port 465) and STARTTLS (port 587)."""
    msg = MIMEMultipart("alternative")
    msg["Subject"] = Header(subject, "utf-8")
    msg["From"] = formataddr((str(Header(from_name, "utf-8")), from_email))
    msg["To"] = to
    msg.attach(MIMEText(html, "html", "utf-8"))

    # Timeout 5s: 4 worker thread'а × 15s при флапе SMTP замораживали весь pipeline.
    # 5s покрывает нормальную доставку с запасом, при недоступности SMTP fallback
    # через enqueue_notification → WP cron сработает в течение пары минут.
    try:
        if SMTP_SECURE == "ssl":
            with smtplib.SMTP_SSL(SMTP_HOST, SMTP_PORT, timeout=5) as server:
                if SMTP_USER and SMTP_PASSWORD:
                    server.login(SMTP_USER, SMTP_PASSWORD)
                server.sendmail(from_email, [to], msg.as_string())
        else:
            with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=5) as server:
                server.ehlo()
                if SMTP_SECURE == "tls":
                    server.starttls()
                    server.ehlo()
                if SMTP_USER and SMTP_PASSWORD:
                    server.login(SMTP_USER, SMTP_PASSWORD)
                server.sendmail(from_email, [to], msg.as_string())
        return True
    except Exception:
        # Не светим адрес получателя — exception-трейсбэк может содержать SMTP response,
        # который у некоторых серверов эхо-репитится с адресом. Хешируем для корреляции.
        to_hash = hashlib.sha256(to.encode("utf-8")).hexdigest()[:12]
        logger.exception("SMTP send failed to_sha=%s", to_hash)
        return False


# =====================================================================
# Public API
# =====================================================================

def send_transaction_new(
    user_id: int,
    partner: str,
    offer_name: str,
    sum_order: Any,
    order_status: str,
) -> bool:
    """
    Send 'new transaction' email notification to user.
    Returns True if sent, False if skipped or failed.
    """
    if not is_configured():
        return False

    if user_id <= 0:
        return False

    if not _is_notification_enabled(user_id, "transaction_new"):
        logger.debug("Notification disabled for user_id=%s type=transaction_new", user_id)
        return False

    user_info = _get_user_email(user_id)
    if not user_info:
        return False

    email, display_name = user_info
    if not email:
        return False

    # Sender from WordPress settings
    from_name, from_email = _get_sender_settings()
    if not from_email:
        logger.warning("No sender email configured, skipping notification")
        return False

    shop = offer_name or "—"
    try:
        sum_formatted = f"{float(sum_order):,.2f}".replace(",", " ").replace(".", ",")
    except (ValueError, TypeError):
        sum_formatted = "—"

    site_url = _get_site_url()
    history_url = f"{site_url}/my-account/cashback-history/" if site_url else ""

    subject = f"Новая покупка в магазине {shop}"

    body = (
        f"Здравствуйте, {display_name or 'пользователь'}!\n\n"
        f"Ваша покупка зафиксирована.\n\n"
        f"Магазин: {shop}\n"
        f"Сумма заказа: {sum_formatted} ₽\n"
        f"Статус: В ожидании\n\n"
        f"Отслеживайте статус в личном кабинете: {history_url}"
    )

    html = _render_html(subject, body, from_name, user_id)
    sent = _send_email(email, subject, html, from_name, from_email)

    if sent:
        # Не пишем e-mail в plaintext: docker logs webhook-worker рассылает таблицу
        # user_id ↔ email кому угодно с доступом к docker socket. Хешируем для корреляции.
        email_hash = hashlib.sha256(email.encode("utf-8")).hexdigest()[:12]
        logger.info("Email sent to user_id=%s (sha=%s): transaction_new", user_id, email_hash)
    return sent
