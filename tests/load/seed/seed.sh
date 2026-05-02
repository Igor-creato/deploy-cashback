#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  Seed test data on the stand via wp-cli (over SSH).
#  Идемпотентно: повторный запуск не дублирует записи.
#  Запускать с нагрузочной машины: ./run.sh seed
# ═══════════════════════════════════════════════════════════════════════
# shellcheck disable=SC2029  # переменные намеренно раскрываются на клиенте перед SSH
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${SSH_HOST:?required}"
: "${SSH_USER:?required}"
: "${WP_CONTAINER:?required}"
: "${LOADTEST_PASS:?required}"

LOADTEST_USER_COUNT="${LOADTEST_USER_COUNT:-200}"
LOADTEST_PRODUCT_COUNT="${LOADTEST_PRODUCT_COUNT:-50}"
LOADTEST_CLICK_COUNT="${LOADTEST_CLICK_COUNT:-200}"
SSH_KEY="${SSH_KEY:-~/.ssh/id_rsa}"

SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

echo "[$(date -Iseconds)] === Seed start ==="
echo "  users    = $LOADTEST_USER_COUNT"
echo "  products = $LOADTEST_PRODUCT_COUNT"
echo "  clicks   = $LOADTEST_CLICK_COUNT"
echo "  stand    = $SSH_USER@$SSH_HOST (container: $WP_CONTAINER)"

# ── 1. Включить loadtest_mode на стенде ────────────────────────────────
echo "[$(date -Iseconds)] → setting loadtest_mode=on"
ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" \
  "docker exec $WP_CONTAINER wp option update loadtest_mode on --allow-root"

# ── 2. Загрузить и выполнить PHP-сидеры через wp eval-file ─────────────
upload_and_run() {
  local script_name=$1; shift
  local local_path="$SCRIPT_DIR/$script_name"

  echo "[$(date -Iseconds)] → running $script_name"
  # Копируем во временный файл внутри контейнера через stdin
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" \
    "docker exec -i $WP_CONTAINER tee /tmp/$script_name >/dev/null" < "$local_path"

  # eval-file с переменными окружения
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" \
    "docker exec \
      -e LOADTEST_PASS='$LOADTEST_PASS' \
      -e LOADTEST_USER_COUNT='$LOADTEST_USER_COUNT' \
      -e LOADTEST_PRODUCT_COUNT='$LOADTEST_PRODUCT_COUNT' \
      -e LOADTEST_CLICK_COUNT='$LOADTEST_CLICK_COUNT' \
      $WP_CONTAINER wp eval-file /tmp/$script_name --allow-root"

  ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" \
    "docker exec $WP_CONTAINER rm -f /tmp/$script_name"
}

upload_and_run seed_users.php
upload_and_run seed_products.php
upload_and_run seed_clicks.php

# ── 3. Выгрузить артефакты для k6 ──────────────────────────────────────
# k6 сценарии читают список созданных user_id, product_id, click_id из JSON-файлов.
# Кладём в seed/data/ — они монтируются в контейнер k6.
mkdir -p "$SCRIPT_DIR/data"

echo "[$(date -Iseconds)] → exporting seed manifests"
# Опция уже хранится как JSON-строка → берём raw без --format, чтобы не дополучить кавычки.
ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" \
  "docker exec $WP_CONTAINER wp option get loadtest_users_manifest --allow-root" \
  > "$SCRIPT_DIR/data/users.json"

ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" \
  "docker exec $WP_CONTAINER wp option get loadtest_products_manifest --allow-root" \
  > "$SCRIPT_DIR/data/products.json"

ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" \
  "docker exec $WP_CONTAINER wp option get loadtest_clicks_manifest --allow-root" \
  > "$SCRIPT_DIR/data/clicks.json"

echo "[$(date -Iseconds)] === Seed done ==="
echo "  Manifests in: $SCRIPT_DIR/data/"
ls -la "$SCRIPT_DIR/data/"
