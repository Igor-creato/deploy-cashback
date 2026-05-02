#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════
#  fix-wp-perms.sh — приведение прав /volumes/wordpress
#  к рекомендованному WordPress Hardening Guide состоянию
#  плюс делегация записи в wp-content администратору хоста
#  через POSIX ACL (без смены владельца www-data).
#
#  Запуск:  sudo bash fix-wp-perms.sh [WP_ROOT]
#
#  Idempotent: повторные запуски безопасны.
# ═══════════════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

# ─── Pre-flight ─────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  err "Запуск только от root:  sudo bash $(basename "$0")"
  exit 1
fi

# Защита от случайных --флагов: скрипт не принимает опции, только путь.
# Без этого `--check` или `--help` интерпретировались как WP_ROOT, и dirname
# падал на минусы → WP_ROOT превращался в текущий PWD ($HOME), и chown -R 33:33
# уносил в /home/USER всё подряд (включая ~/.ssh — потеря SSH-доступа).
if [[ "${1:-}" == --* ]]; then
  err "Неизвестный флаг: $1"
  err "Скрипт не принимает опции. Использование:"
  err "  sudo bash $(basename "$0")              # WP_ROOT по умолчанию"
  err "  sudo bash $(basename "$0") /path/to/wp  # явный путь"
  exit 1
fi

# REAL_USER_OVERRIDE имеет приоритет над SUDO_USER (нужно для restore-all.sh).
REAL_USER="${REAL_USER_OVERRIDE:-${SUDO_USER:-root}}"
REAL_GROUP="$(id -gn "$REAL_USER" 2>/dev/null || echo "root")"

# WP_ROOT: $1 → env WP_ROOT → авто (../volumes/wordpress относительно скрипта).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Подхватить DEPLOY_USER из cashback.env при прямом запуске
# (sudo bash fix-wp-perms.sh). При вызове из restore-all.sh переменная
# уже в env — в этом случае source ничего не меняет.
if [[ -z "${DEPLOY_USER:-}" ]]; then
  CASHBACK_ENV_CANDIDATE="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd)/cashback.env"
  if [[ -f "$CASHBACK_ENV_CANDIDATE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$CASHBACK_ENV_CANDIDATE"; set +a
  fi
fi
WP_ROOT="${1:-${WP_ROOT:-${SCRIPT_DIR}/../volumes/wordpress}}"
WP_ROOT="$(cd "$(dirname "$WP_ROOT")" 2>/dev/null && pwd)/$(basename "$WP_ROOT")" || true

# ─── Sanity guard: запрет разрушительных целей ──────────────
# Скрипт делает chown -R 33:33 + chmod -R на весь WP_ROOT. Если случайно
# WP_ROOT окажется системным каталогом ($HOME, /, /home, /root, /etc, /var,
# /usr, /tmp), это уничтожит права всему что внутри. Лучше отказать сразу.
case "$WP_ROOT" in
  ""|"/"|"/home"|"/home/"|"/root"|"/root/"|"/etc"|"/etc/"|"/var"|"/var/"|"/usr"|"/usr/"|"/tmp"|"/tmp/"|"/opt"|"/opt/")
    err "WP_ROOT=${WP_ROOT} — системный/корневой путь, запуск запрещён"
    exit 1
    ;;
esac
# Запрет на $HOME пользователя (любого) — типичная мишень случайной аварии.
if [[ "$WP_ROOT" == "$HOME" || "$WP_ROOT" == "$HOME/" ]]; then
  err "WP_ROOT=${WP_ROOT} совпадает с \$HOME — запуск запрещён"
  exit 1
fi
# Запрет если внутри есть характерные не-WP файлы (signs of homedir).
if [[ -e "$WP_ROOT/.ssh" || -e "$WP_ROOT/.bashrc" || -e "$WP_ROOT/.bash_history" ]]; then
  err "WP_ROOT=${WP_ROOT} содержит home-dir файлы (.ssh/.bashrc/.bash_history)"
  err "Отказ — это явно не каталог WordPress"
  exit 1
fi

info "WP_ROOT     = ${WP_ROOT}"
info "REAL_USER   = ${REAL_USER} (${REAL_GROUP})"

# ─── Каталог wordpress ──────────────────────────────────────
if [[ ! -d "$WP_ROOT" ]]; then
  info "Каталог ${WP_ROOT} не существует — создаю как 33:33 0755"
  install -d -o 33 -g 33 -m 0755 "$WP_ROOT"
fi

# ─── Установка пакета acl (если нет) ────────────────────────
if ! command -v setfacl >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    info "Пакет acl не установлен — ставлю через apt-get"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq acl
  else
    err "Утилита setfacl не найдена и apt-get недоступен."
    err "Установите пакет acl вручную (на Debian/Ubuntu: apt-get install acl)."
    exit 1
  fi
fi

# ─── Проверка поддержки ACL файловой системой ───────────────
ACL_TEST_DIR="$(mktemp -d -p "$WP_ROOT" .acl-test.XXXXXX 2>/dev/null || true)"
if [[ -z "$ACL_TEST_DIR" || ! -d "$ACL_TEST_DIR" ]]; then
  err "Не удалось создать тестовый каталог в ${WP_ROOT}"
  exit 1
fi
if ! setfacl -m u:root:rwx "$ACL_TEST_DIR" 2>/dev/null; then
  rmdir "$ACL_TEST_DIR" 2>/dev/null || true
  err "Файловая система не поддерживает ACL для ${WP_ROOT}."
  err "На ext4/xfs ACL включена по умолчанию. Проверьте: mount | grep \"$(stat -c '%m' "$WP_ROOT")\""
  err "При необходимости перемонтируйте с опцией acl или включите в /etc/fstab."
  exit 1
fi
rmdir "$ACL_TEST_DIR" 2>/dev/null || true

# ─── Базовые WP-права (Hardening Guide) ─────────────────────
# Владелец остаётся www-data (uid 33, gid 33) — иначе сломается контейнер.
info "Установка владельца ${WP_ROOT} → www-data:www-data (33:33)"
chown -R 33:33 "$WP_ROOT"

info "Установка стандартных прав WordPress (dir 0755, file 0644)"
find "$WP_ROOT" -type d -exec chmod 0755 {} +
find "$WP_ROOT" -type f -exec chmod 0644 {} +

# wp-config.php — особый режим (читается только владельцем и группой).
if [[ -f "${WP_ROOT}/wp-config.php" ]]; then
  chmod 0640 "${WP_ROOT}/wp-config.php"
  info "wp-config.php → 0640"
fi

# ─── service/secrets/ → dir 0700 ────────────────────────────
# Защита периметра docker-secrets. install.sh ставит 0700, но restore-all.sh
# и ручные операции могут сбить до 0755 (видели регрессию 2026-05-02).
# Сами файлы внутри остаются 0644 — это by design (см. ../SECRETS.md):
# контейнеры grafana (UID 472) и mysqld-exporter (UID 65534) читают через
# bind-mount, и если поставить 0600 owned host-UID, они получат permission denied.
SECRETS_DIR="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)/secrets"
if [[ -d "$SECRETS_DIR" ]]; then
  chmod 0700 "$SECRETS_DIR"
  info "secrets/ → 0700 (содержимое не трогаем)"
fi

# ─── ACL для wp-content/ ────────────────────────────────────
WP_CONTENT="${WP_ROOT}/wp-content"
if [[ ! -d "$WP_CONTENT" ]]; then
  info "Каталог ${WP_CONTENT} не существует — создаю как 33:33 0755"
  install -d -o 33 -g 33 -m 0755 "$WP_CONTENT"
fi

if [[ "$REAL_USER" == "root" ]]; then
  info "REAL_USER=root — нечего делегировать через ACL, пропускаю шаг setfacl"
else
  info "Применение ACL: u:${REAL_USER}:rwX на ${WP_CONTENT} (рекурсивно)"
  setfacl -R -m "u:${REAL_USER}:rwX" "$WP_CONTENT"

  info "Применение default ACL для новых файлов в ${WP_CONTENT}"
  # Default ACL наследуется новыми файлами/папками. Симметрично гарантируем
  # доступ www-data (uid 33), чтобы файлы, созданные REAL_USER через scp,
  # оставались доступны для записи WordPress'у в контейнере.
  setfacl -R -d -m "u::rwx"                "$WP_CONTENT"
  setfacl -R -d -m "u:${REAL_USER}:rwx"    "$WP_CONTENT"
  setfacl -R -d -m "u:33:rwx"              "$WP_CONTENT"
  setfacl -R -d -m "g::r-x"                "$WP_CONTENT"
  setfacl -R -d -m "g:33:rwx"              "$WP_CONTENT"
  setfacl -R -d -m "o::r-x"                "$WP_CONTENT"
  setfacl -R -d -m "m::rwx"                "$WP_CONTENT"

  log "ACL установлены: ${REAL_USER} получил rwx на ${WP_CONTENT}"
fi

# ─── Дополнительный CI/CD пользователь (опционально) ────────
# DEPLOY_USER (например "deployer" для GitHub Actions) получает те же
# ACL-права на wp-content, чтобы `git pull` через SSH в плагине-репо
# не падал с `cannot open .git/FETCH_HEAD: Permission denied` после
# ребилда volume / restore. Пустая переменная = блок пропускается.
DEPLOY_USER="${DEPLOY_USER:-}"
if [[ -n "$DEPLOY_USER" && "$DEPLOY_USER" != "$REAL_USER" && "$DEPLOY_USER" != "root" ]]; then
  if ! id -u "$DEPLOY_USER" >/dev/null 2>&1; then
    warn "DEPLOY_USER=${DEPLOY_USER} не существует в системе — пропускаю ACL для него"
  else
    info "Применение ACL: u:${DEPLOY_USER}:rwX на ${WP_CONTENT} (рекурсивно)"
    setfacl -R -m "u:${DEPLOY_USER}:rwX" "$WP_CONTENT"

    info "Default ACL для ${DEPLOY_USER} (новые файлы)"
    setfacl -R -d -m "u:${DEPLOY_USER}:rwx" "$WP_CONTENT"

    log "ACL установлены: ${DEPLOY_USER} получил rwx на ${WP_CONTENT}"
  fi
fi

# ─── Подтверждение ──────────────────────────────────────────
echo ""
info "Текущий ACL ${WP_CONTENT}:"
getfacl --omit-header "$WP_CONTENT" 2>/dev/null | head -20 || true
echo ""

log "Права на ${WP_ROOT} приведены к корректному состоянию"
