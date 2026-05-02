#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  Импорт load-test-dashboard.json в Grafana стенда через HTTP API.
#  Запускать с нагрузочной машины: ./grafana/import.sh
#
#  Чтобы не смешивать тестовые артефакты со стек-volumes стенда —
#  дашборд лежит ТОЛЬКО здесь, а не в service/volumes/grafana/dashboards/.
#  При повторном импорте перезаписывает существующий (overwrite=true).
# ═══════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a; source "$ROOT_DIR/.env"; set +a
fi

: "${GRAFANA_URL:?Set GRAFANA_URL in .env (e.g. http://stand.example.com:3000)}"
: "${GRAFANA_API_TOKEN:?Set GRAFANA_API_TOKEN in .env (Service account → Token)}"

DASHBOARD_FILE="$SCRIPT_DIR/load-test-dashboard.json"
[[ -f "$DASHBOARD_FILE" ]] || { echo "Dashboard file not found: $DASHBOARD_FILE" >&2; exit 1; }

# Grafana ожидает {"dashboard": {...}, "overwrite": true, "folderUid": ""}
PAYLOAD=$(jq -n --slurpfile dash "$DASHBOARD_FILE" \
  '{dashboard: $dash[0], overwrite: true, folderUid: ""}')

echo "→ Importing dashboard to $GRAFANA_URL..."
RESPONSE=$(curl -sS -X POST "$GRAFANA_URL/api/dashboards/db" \
  -H "Authorization: Bearer $GRAFANA_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

if echo "$RESPONSE" | jq -e '.uid' >/dev/null 2>&1; then
  URL_PATH=$(echo "$RESPONSE" | jq -r '.url')
  echo "  ✓ imported: $GRAFANA_URL$URL_PATH"
else
  echo "  ✗ import failed:"
  echo "$RESPONSE" | jq . >&2 || echo "$RESPONSE" >&2
  exit 1
fi
