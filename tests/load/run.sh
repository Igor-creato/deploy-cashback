#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  cash-back load test runner
#  Usage: ./run.sh <scenario|seed|teardown> [extra k6 args...]
#  Запускать на нагрузочной машине (отдельная VM/ноут с Docker).
# ═══════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── 1. Загрузка .env ────────────────────────────────────────────────────
if [[ ! -f .env ]]; then
  echo "ERROR: .env not found. Copy .env.example → .env and fill in values." >&2
  exit 1
fi
set -a; source .env; set +a

ACTION="${1:-}"
shift || true

require_env() {
  local var=$1
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: $var is not set in .env" >&2
    exit 1
  fi
}

# ── 2. Команды seed/teardown — отдельные ветки ─────────────────────────
if [[ "$ACTION" == "seed" ]]; then
  require_env SSH_HOST; require_env SSH_USER; require_env WP_CONTAINER
  require_env LOADTEST_PASS
  exec bash "$SCRIPT_DIR/seed/seed.sh" "$@"
fi

if [[ "$ACTION" == "teardown" ]]; then
  require_env SSH_HOST; require_env SSH_USER; require_env WP_CONTAINER
  exec bash "$SCRIPT_DIR/teardown/teardown.sh" "$@"
fi

# ── 3. Сценарии k6 ──────────────────────────────────────────────────────
SCENARIO_FILE="k6/scenario_${ACTION}.js"
if [[ ! -f "$SCENARIO_FILE" ]]; then
  echo "Usage: $0 <scenario>"
  echo "Available scenarios:"
  ls k6/scenario_*.js | sed 's|k6/scenario_||;s|\.js||' | sed 's/^/  - /'
  echo "Special:"
  echo "  - seed       (provision test data on stand via wp-cli)"
  echo "  - teardown   (remove all loadtest_* data)"
  exit 1
fi

require_env BASE_URL
require_env WEBHOOK_URL
require_env LOADTEST_PASS

# webhook-сценарии требуют HMAC + slug
if [[ "$ACTION" == webhook_* ]]; then
  require_env NETWORK_SLUG
  require_env WEBHOOK_SECRET_PATH
  require_env HMAC_SECRET
fi

# ── 4. Pre-test sanity ──────────────────────────────────────────────────
echo "[$(date -Iseconds)] === Pre-test sanity check ==="

SSH_PORT="${SSH_PORT:-22}"
SSH_KEY_PATH="${SSH_KEY:-~/.ssh/id_rsa}"
REDIS_CONTAINER="${REDIS_CONTAINER:-redis}"
SSH_BASE=(ssh -i "$SSH_KEY_PATH" -p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

# 4a. loadtest_mode на стенде должен быть on
if "${SSH_BASE[@]}" "$SSH_USER@$SSH_HOST" \
     "docker exec $WP_CONTAINER wp option get loadtest_mode --allow-root 2>/dev/null" | grep -q '^on$'; then
  echo "  ✓ loadtest_mode=on"
else
  echo "  ✗ loadtest_mode is NOT 'on' on stand. Run: ./run.sh seed (it will set the flag)" >&2
  exit 1
fi

# 4b. Webhook receiver health (если webhook-сценарий)
if [[ "$ACTION" == webhook_* ]]; then
  if ! curl -sf "$WEBHOOK_URL/health" -o /dev/null; then
    echo "  ✗ Webhook receiver $WEBHOOK_URL/health не отвечает" >&2
    exit 1
  fi
  echo "  ✓ webhook receiver healthy"
fi

# 4c. Очистка кэшей и очередей перед прогоном
echo "[$(date -Iseconds)] === Pre-test cleanup ==="
"${SSH_BASE[@]}" "$SSH_USER@$SSH_HOST" \
  "docker exec $WP_CONTAINER wp cache flush --allow-root 2>/dev/null || true; \
   docker exec $REDIS_CONTAINER redis-cli -n 1 DEL webhook:queue webhook:dlq >/dev/null || true"
echo "  ✓ caches and queues flushed"

# ── 5. Подготовка результатов ──────────────────────────────────────────
TS="$(date +%Y-%m-%d-%H%M%S)"
RUN_DIR="$SCRIPT_DIR/results/$TS-$ACTION"
mkdir -p "$RUN_DIR"
echo "[$(date -Iseconds)] === Run dir: $RUN_DIR ==="

# Сохранить срез конфига стенда (для verdict.md)
"${SSH_BASE[@]}" "$SSH_USER@$SSH_HOST" \
    "git -C ~/cash-back/deploy-cashback log -1 --format='%H %s' 2>/dev/null || echo 'no-git'" \
    > "$RUN_DIR/stand-version.txt" || true

# ── 6. Grafana annotation: начало прогона ───────────────────────────────
START_TS_MS=$(($(date +%s%N) / 1000000))
if [[ -n "${GRAFANA_API_TOKEN:-}" ]]; then
  curl -s -X POST "$GRAFANA_URL/api/annotations" \
    -H "Authorization: Bearer $GRAFANA_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"text\":\"load-test START $ACTION\",\"tags\":[\"loadtest\",\"$ACTION\"],\"time\":$START_TS_MS}" \
    > "$RUN_DIR/annotation-start.json" || true
fi

# ── 7. Запуск k6 ────────────────────────────────────────────────────────
TEST_ID="${ACTION}-${TS}"
echo "[$(date -Iseconds)] === Running k6 scenario: $ACTION (testid=$TEST_ID) ==="

K6_OUT_ARGS=()
if [[ -n "${VM_REMOTE_WRITE:-}" ]]; then
  K6_OUT_ARGS+=("--out" "experimental-prometheus-rw=$VM_REMOTE_WRITE")
  export K6_PROMETHEUS_RW_TREND_STATS="p(50),p(95),p(99),avg,max"
fi

docker run --rm -i \
  --network host \
  -v "$SCRIPT_DIR/k6:/scripts:ro" \
  -e BASE_URL \
  -e WEBHOOK_URL \
  -e NETWORK_SLUG \
  -e WEBHOOK_SECRET_PATH \
  -e HMAC_SECRET \
  -e LOADTEST_PASS \
  -e LOADTEST_USER_COUNT \
  -e LOADTEST_PRODUCT_COUNT \
  -e K6_PROMETHEUS_RW_TREND_STATS \
  grafana/k6:latest run \
    --tag testid="$TEST_ID" \
    --summary-export="/scripts/../results/$TS-$ACTION/summary.json" \
    "${K6_OUT_ARGS[@]}" \
    "/scripts/scenario_${ACTION}.js" \
    "$@" 2>&1 | tee "$RUN_DIR/k6-stdout.log"

K6_EXIT=${PIPESTATUS[0]}

# ── 8. Grafana annotation: конец прогона ───────────────────────────────
END_TS_MS=$(($(date +%s%N) / 1000000))
if [[ -n "${GRAFANA_API_TOKEN:-}" ]]; then
  curl -s -X POST "$GRAFANA_URL/api/annotations" \
    -H "Authorization: Bearer $GRAFANA_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"text\":\"load-test END $ACTION (exit=$K6_EXIT)\",\"tags\":[\"loadtest\",\"$ACTION\"],\"time\":$END_TS_MS}" \
    > "$RUN_DIR/annotation-end.json" || true
fi

# ── 9. Метрики из VictoriaMetrics за интервал теста ────────────────────
if [[ -n "${VM_REMOTE_WRITE:-}" ]]; then
  VM_QUERY_BASE="${VM_REMOTE_WRITE%/api/v1/write}"
  START_S=$((START_TS_MS / 1000))
  END_S=$((END_TS_MS / 1000))
  echo "[$(date -Iseconds)] === Snapshotting VM metrics (${START_S}..${END_S}) ==="

  # Ключевые серии для verdict.md
  declare -a QUERIES=(
    "phpfpm_active_processes"
    "phpfpm_listen_queue"
    "phpfpm_max_children_reached_total"
    "mysql_global_status_threads_running"
    "mysql_global_status_threads_connected"
    "mysql_global_status_aborted_connects"
    "redis_memory_used_bytes"
    "redis_db_keys{db=\"db1\"}"
    "node_load1"
    "node_memory_MemAvailable_bytes"
    "rate(nginx_http_requests_total[1m])"
  )

  : > "$RUN_DIR/metrics-snapshot.json"
  for q in "${QUERIES[@]}"; do
    curl -sG "$VM_QUERY_BASE/api/v1/query_range" \
      --data-urlencode "query=$q" \
      --data-urlencode "start=$START_S" \
      --data-urlencode "end=$END_S" \
      --data-urlencode "step=15s" \
      | jq --arg q "$q" '. + {query: $q}' >> "$RUN_DIR/metrics-snapshot.json" || true
  done
fi

# ── 10. Шаблон verdict.md ──────────────────────────────────────────────
cat > "$RUN_DIR/verdict.md" <<MARKDOWN
# $TEST_ID

- Date: $(date -Iseconds)
- Stand version: $(cat "$RUN_DIR/stand-version.txt" 2>/dev/null || echo unknown)
- k6 exit code: $K6_EXIT
- Duration: $((END_S - START_S))s

## Verdict
- [ ] PASS / [ ] FAIL

## Bottleneck (if any)
<!-- Что начало деградировать первым: FPM listen queue / MySQL Threads_running / Redis evicted / RAM / iowait / др. -->

## Config changes BEFORE this run
<!-- git diff --stat от предыдущего успешного прогона -->

## Next change to try
<!-- Один параметр на следующий ретест -->
MARKDOWN

echo "[$(date -Iseconds)] === Done. Results in: $RUN_DIR ==="
echo "  - summary.json"
echo "  - metrics-snapshot.json"
echo "  - verdict.md  ← заполни вручную"
exit $K6_EXIT
