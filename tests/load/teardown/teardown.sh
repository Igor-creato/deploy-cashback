#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  Teardown — удаляет все loadtest_* данные со стенда.
#  Запускать с нагрузочной машины: ./run.sh teardown
#  ВНИМАНИЕ: операция деструктивна. Скрипт удалит ТОЛЬКО записи с префиксом
#  loadtest_ и/или _loadtest=1 — но запросит подтверждение.
# ═══════════════════════════════════════════════════════════════════════
set -euo pipefail

: "${SSH_HOST:?required}"
: "${SSH_USER:?required}"
: "${WP_CONTAINER:?required}"
SSH_KEY="${SSH_KEY:-~/.ssh/id_rsa}"
SSH_PORT="${SSH_PORT:-22}"
REDIS_CONTAINER="${REDIS_CONTAINER:-redis}"
WP_CONTAINER="${WP_CONTAINER:-wordpress}"

echo "=== Teardown plan ==="
echo "Will DELETE on stand $SSH_HOST:"
echo "  • all WP users with login like 'loadtest_user_%'"
echo "  • all WC products with slug like 'loadtest-product-%' AND meta _loadtest=1"
echo "  • all rows in wp_cashback_click_log with affiliate_url LIKE 'https://partner.example/%'"
echo "  • all rows in wp_cashback_transactions for those user_ids"
echo "  • Redis lists webhook:queue, webhook:dlq (DB 1)"
echo "  • options loadtest_*"
echo

read -r -p "Continue? (type 'YES'): " confirm
if [[ "$confirm" != "YES" ]]; then
  echo "Aborted."; exit 1
fi

SSH_OPTS=(-i "$SSH_KEY" -p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "WP_CONTAINER='$WP_CONTAINER' REDIS_CONTAINER='$REDIS_CONTAINER' bash -se" <<'REMOTE'
set -e
WP="docker exec $WP_CONTAINER wp --allow-root"

echo "→ delete users by login prefix"
USER_IDS=$($WP db query \
  "SELECT GROUP_CONCAT(ID) FROM wp_users WHERE user_login LIKE 'loadtest_user_%';" \
  --skip-column-names || true)
if [[ -n "$USER_IDS" && "$USER_IDS" != "NULL" ]]; then
  $WP user delete $USER_IDS --yes --reassign=1 || true
else
  echo "  (no loadtest users found)"
fi

echo "→ delete loadtest products"
PROD_IDS=$($WP db query \
  "SELECT GROUP_CONCAT(p.ID) FROM wp_posts p
     JOIN wp_postmeta m ON m.post_id = p.ID
   WHERE p.post_type='product' AND p.post_name LIKE 'loadtest-product-%'
     AND m.meta_key='_loadtest' AND m.meta_value='1';" \
  --skip-column-names || true)
if [[ -n "$PROD_IDS" && "$PROD_IDS" != "NULL" ]]; then
  $WP post delete $PROD_IDS --force --yes || true
else
  echo "  (no loadtest products found)"
fi

echo "→ purge cashback_click_log loadtest rows"
$WP db query "DELETE FROM wp_cashback_click_log WHERE affiliate_url LIKE 'https://partner.example/%';" || true

echo "→ purge cashback_transactions for ghost users"
$WP db query "DELETE FROM wp_cashback_transactions WHERE user_id NOT IN (SELECT ID FROM wp_users);" || true

echo "→ purge cashback_webhooks loadtest rows"
$WP db query "DELETE FROM wp_cashback_webhooks WHERE network_slug='loadtest' OR payload LIKE '%loadtest%';" || true

echo "→ flush Redis queue/dlq"
docker exec "$REDIS_CONTAINER" redis-cli -n 1 DEL webhook:queue webhook:dlq >/dev/null || true

echo "→ remove loadtest options"
$WP option delete loadtest_users_manifest loadtest_products_manifest loadtest_clicks_manifest 2>/dev/null || true
$WP option update loadtest_mode off

echo "→ done"
REMOTE

echo "=== Teardown complete ==="
