#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# render-configs.sh — единый ре-рендер конфигов из .tpl.
#
# Единственный источник правды для генерации:
#   - volumes/traefik/traefik.yml      ← ${ACME_EMAIL}
#   - volumes/nginx/default.conf       ← ${NGINX_SERVER_NAMES}
#   - volumes/grafana/.../contact-points.yml ← ${ALERT_EMAIL}
#
# Значения берутся ТОЛЬКО из service/.env (канонический файл, его же
# читает docker compose). Никакого хардкода — на любом сервере одна
# команда: `bash service/render-configs.sh`.
#
# install.sh вызывает этот скрипт после создания .env, поэтому
# install-рендер и ручной ре-рендер байт-идентичны. Все три выходных
# файла в .gitignore — рабочее дерево остаётся чистым.
#
# Идемпотентно, без побочных эффектов кроме перезаписи 3 generated-файлов.
# ═══════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
VOL="$SCRIPT_DIR/volumes"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE не найден — сначала запустите install.sh" >&2
  exit 1
fi
if ! command -v envsubst &>/dev/null; then
  echo "ERROR: envsubst отсутствует (apt-get install -y gettext-base)" >&2
  exit 1
fi

# Достаём ключ из .env безопасно (значения могут содержать пробелы,
# напр. NGINX_SERVER_NAMES) — без `source`, который ломается на таких.
read_env() { grep -E "^$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2- ; }

DOMAIN="$(read_env DOMAIN)"
ACME_EMAIL="$(read_env ACME_EMAIL)"
ALERT_EMAIL="$(read_env ALERT_EMAIL)"
NGINX_SERVER_NAMES="$(read_env NGINX_SERVER_NAMES)"
# Тот же fallback, что в install.sh.
[[ -n "$NGINX_SERVER_NAMES" ]] || NGINX_SERVER_NAMES="$DOMAIN localhost 127.0.0.1 nginx"

if [[ -z "$ACME_EMAIL" ]]; then
  echo "ERROR: ACME_EMAIL пуст/отсутствует в $ENV_FILE — добавьте 'ACME_EMAIL=<email>'" >&2
  exit 1
fi
[[ -n "$ALERT_EMAIL" ]] || echo "WARN: ALERT_EMAIL пуст — contact-points.yml будет без адреса" >&2

# ── traefik.yml ──
TPL="$VOL/traefik/traefik.yml.tpl"
if [[ -f "$TPL" ]]; then
  ACME_EMAIL="$ACME_EMAIL" envsubst '${ACME_EMAIL}' < "$TPL" > "$VOL/traefik/traefik.yml"
  chmod 644 "$VOL/traefik/traefik.yml"
  echo "✓ traefik.yml (ACME_EMAIL=$ACME_EMAIL)"
else
  echo "WARN: $TPL не найден — пропуск traefik" >&2
fi

# ── nginx default.conf ──
TPL="$VOL/nginx/default.conf.tpl"
if [[ -f "$TPL" ]]; then
  NGINX_SERVER_NAMES="$NGINX_SERVER_NAMES" envsubst '${NGINX_SERVER_NAMES}' < "$TPL" > "$VOL/nginx/default.conf"
  chmod 644 "$VOL/nginx/default.conf"
  echo "✓ default.conf (server_name: $NGINX_SERVER_NAMES)"
else
  echo "WARN: $TPL не найден — пропуск nginx" >&2
fi

# ── grafana contact-points.yml ──
TPL="$VOL/grafana/provisioning/alerting/contact-points.yml.tpl"
if [[ -f "$TPL" ]]; then
  ALERT_EMAIL="$ALERT_EMAIL" envsubst '${ALERT_EMAIL}' < "$TPL" > "${TPL%.tpl}"
  chmod 644 "${TPL%.tpl}"
  echo "✓ contact-points.yml (ALERT_EMAIL=$ALERT_EMAIL)"
else
  echo "WARN: $TPL не найден — пропуск grafana" >&2
fi

echo "OK — конфиги перегенерированы из $ENV_FILE"
