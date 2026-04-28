#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════
#  Финализация WordPress после прохождения мастера установки.
#
#  Запускать ПОСЛЕ того, как открыл https://${DOMAIN} и прошёл
#  пятиминутный мастер WordPress (Site Title, Username, Email).
#
#  Что делает (всё идемпотентно — можно перезапускать):
#    1) проверяет, что WP установлен (есть таблицы)
#    2) ставит и активирует плагин redis-cache (если ещё нет)
#    3) включает Redis Object Cache (создаёт/обновляет drop-in
#       wp-content/object-cache.php)
#    4) проверяет, что выбран нативный клиент PhpRedis (не Predis)
#
#  Использование:
#     bash scripts/finalize-wordpress.sh
# ═══════════════════════════════════════════════════════════

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC}   $*"; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC}  $*" >&2; }

WP="docker exec -u www-data wordpress wp --allow-root"

# ── 0. Контейнер запущен? ────────────────────────────────
if ! docker ps --format '{{.Names}}' | grep -qx wordpress; then
  err "Контейнер 'wordpress' не запущен. Сначала: docker compose up -d"
  exit 1
fi

# ── 1. PhpRedis в образе? (sanity-check) ─────────────────
if ! docker exec wordpress php -m 2>/dev/null | grep -qx redis; then
  warn "В PHP не загружено расширение redis."
  warn "Нужно пересобрать образ:  docker compose build wordpress && docker compose up -d wordpress"
  warn "После пересборки запусти этот скрипт снова."
  exit 1
fi
log "PHP-расширение redis загружено"

# ── 2. WordPress установлен? ─────────────────────────────
if ! $WP core is-installed >/dev/null 2>&1; then
  warn "WordPress ещё не установлен."
  warn "Открой https://\${DOMAIN} и пройди мастер установки, затем запусти этот скрипт снова."
  exit 0
fi
log "WordPress установлен"

# ── 3. Плагин redis-cache: установить + активировать ─────
if ! $WP plugin is-installed redis-cache >/dev/null 2>&1; then
  info "Устанавливаю плагин redis-cache..."
  $WP plugin install redis-cache >/dev/null
  log "Плагин redis-cache установлен"
else
  log "Плагин redis-cache уже установлен"
fi

if ! $WP plugin is-active redis-cache >/dev/null 2>&1; then
  info "Активирую плагин redis-cache..."
  $WP plugin activate redis-cache >/dev/null
  log "Плагин redis-cache активирован"
else
  log "Плагин redis-cache уже активирован"
fi

# ── 4. Включить object cache (создать/обновить drop-in) ──
# wp redis enable идемпотентен: если drop-in уже на месте — он его обновит
# до текущей версии плагина (это и нужно после смены клиента Predis→PhpRedis).
info "Включаю Redis Object Cache (создаю/обновляю object-cache.php drop-in)..."
if $WP redis enable >/dev/null 2>&1; then
  log "Redis Object Cache включён"
else
  # Если уже включён, enable вернёт ненулевой код — попробуем update-dropin.
  if $WP redis update-dropin >/dev/null 2>&1; then
    log "Redis Object Cache drop-in обновлён"
  else
    warn "Не удалось вызвать 'wp redis enable' / 'update-dropin'. Проверь:"
    warn "  $WP redis status"
  fi
fi

# ── 5. Какой клиент выбран? ──────────────────────────────
STATUS_OUT="$($WP redis status 2>/dev/null || true)"
CLIENT_LINE="$(echo "$STATUS_OUT" | grep -E '^Client:' || true)"

if [[ -z "$CLIENT_LINE" ]]; then
  warn "Не удалось получить статус Redis. Запусти вручную:  $WP redis status"
  exit 1
fi

if echo "$CLIENT_LINE" | grep -qi 'PhpRedis'; then
  log "Клиент Redis: ${CLIENT_LINE#Client:}"
  info "Готово. Можно проверить рост памяти Redis после прогрева:"
  echo -e "    ${CYAN}docker exec redis redis-cli info memory | grep used_memory_human${NC}"
else
  warn "Object Cache использует НЕ PhpRedis: ${CLIENT_LINE}"
  warn "Это значит, что расширение redis недоступно WordPress'у."
  warn "Проверь:  docker exec wordpress php -m | grep redis"
  warn "Если расширение есть, но клиент всё равно Predis — выполни:"
  warn "  $WP redis disable && $WP redis enable"
  exit 1
fi
