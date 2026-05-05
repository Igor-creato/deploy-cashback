#!/bin/sh
set -e

# ── Generate msmtp config from environment ──────────────
if [ -n "$SMTP_HOST" ]; then
  STARTTLS="on"

  # если implicit TLS (465)
  if [ "$SMTP_SECURE" = "ssl" ]; then
    STARTTLS="off"
  fi

  # Пароль читаем из docker secret (SMTP_PASSWORD_FILE) — это снимает
  # видимость через `docker inspect`. Fallback на SMTP_PASSWORD оставлен
  # для обратной совместимости при локальной отладке.
  if [ -n "$SMTP_PASSWORD_FILE" ] && [ -r "$SMTP_PASSWORD_FILE" ]; then
    SMTP_PASSWORD="$(cat "$SMTP_PASSWORD_FILE")"
  fi

  # ── Logfile: ОБЯЗАТЕЛЬНО absolute path. ──
  # Относительный путь "syslog" заставлял msmtp писать в текущую рабочую
  # директорию PHP-скрипта (e.g. /var/www/html/syslog, /var/www/html/wp-admin/syslog),
  # что приводило к утечке email-адресов получателей через HTTP.
  # 2026-05-05: ротация. Файл создаётся www-data:www-data 0600.
  MSMTP_LOG=/var/log/msmtp.log
  touch "${MSMTP_LOG}"
  chown www-data:www-data "${MSMTP_LOG}"
  chmod 0600 "${MSMTP_LOG}"

  cat > /etc/msmtprc <<EOF
defaults
auth           on
tls            on
tls_starttls   ${STARTTLS}
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        ${MSMTP_LOG}

account        default
host           ${SMTP_HOST}
port           ${SMTP_PORT:-587}
from           ${SMTP_FROM:-noreply@localhost}
user           ${SMTP_USER}
password       ${SMTP_PASSWORD}
EOF

  chmod 640 /etc/msmtprc
  chown root:www-data /etc/msmtprc
  unset SMTP_PASSWORD
fi

# ── ВАЖНО: передаём управление оригинальному entrypoint ─
exec docker-entrypoint.sh "$@"