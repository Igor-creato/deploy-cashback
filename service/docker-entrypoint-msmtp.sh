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

  cat > /etc/msmtprc <<EOF
defaults
auth           on
tls            on
tls_starttls   ${STARTTLS}
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        syslog

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