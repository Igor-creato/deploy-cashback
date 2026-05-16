#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# opcache-status.sh — read-only снимок OPcache в КОНТЕКСТЕ php-fpm (не CLI).
#
# Tracking: Igor-creato/deploy-cashback#1
#
# Зачем: подтвердить/опровергнуть root-cause «OPcache restart-storm после
# wp-admin ZIP при validate_timestamps=0». `wp eval` не годится —
# opcache.enable_cli=0, CLI-SAPI не видит FPM-кэш. Поэтому гоняем
# крошечный `opcache_get_status()` через cgi-fcgi на :9000 (тот же пул).
#
# READ-ONLY: opcache_get_status() ничего не меняет. tmp-скрипт живёт в
# /tmp КОНТЕЙНЕРА (не webroot/bind-mount → nginx недостижим, исчезает при
# любом recreate), удаляется по выходу. Никаких инсталляций.
#
# Использование (оператор, на хосте):
#   bash service/scripts/diag/opcache-status.sh
# Вставить в чат весь вывод (компактный — opcache_get_status(false), без
# списка скриптов).
#
# Решающие поля:
#   opcache_statistics.oom_restarts / hash_restarts / manual_restarts
#     — >0 и растёт после релиза = подтверждение restart-storm.
#   restart_pending / restart_in_progress — если поймать во время лупа.
#   cache_full=true, memory_usage.current_wasted_percentage высокий,
#   opcache_statistics.num_cached_keys≈max_cached_keys — давление SHM
#   от невыгруженных старых записей при validate_timestamps=0.
# ═══════════════════════════════════════════════════════════════════════════
set -u -o pipefail

CONTAINER="${CONTAINER:-wordpress}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

command -v docker >/dev/null 2>&1 || { echo "FATAL: docker не найден" >&2; exit 1; }
docker inspect "$CONTAINER" >/dev/null 2>&1 || { echo "FATAL: нет контейнера $CONTAINER" >&2; exit 1; }
docker exec "$CONTAINER" sh -c 'command -v cgi-fcgi' >/dev/null 2>&1 \
  || { echo "FATAL: cgi-fcgi нет в контейнере" >&2; exit 1; }

TMP="/tmp/diag-opcache-$TS.php"
cleanup(){ docker exec "$CONTAINER" rm -f "$TMP" 2>/dev/null; }
trap cleanup EXIT INT TERM

# opcache_get_status(false) — без массива scripts (компактно, paste-friendly).
docker exec "$CONTAINER" sh -c \
  "printf '%s' '<?php header(\"Content-Type: application/json\"); echo json_encode(function_exists(\"opcache_get_status\") ? opcache_get_status(false) : array(\"_err\"=>\"no opcache\"));' > $TMP && chmod 644 $TMP" \
  || { echo "FATAL: не создать $TMP" >&2; exit 1; }

RAW="$(docker exec "$CONTAINER" sh -c \
  "SCRIPT_NAME=/diag-opcache SCRIPT_FILENAME=$TMP REQUEST_METHOD=GET \
   cgi-fcgi -bind -connect 127.0.0.1:9000 2>/dev/null" | sed -n '/{/,$p')"

if [ -z "$RAW" ]; then
  echo "FATAL: пустой ответ от php-fpm :9000 (пул занят/недоступен?)" >&2
  exit 1
fi

echo "════════ OPCACHE STATUS (php-fpm context)  ts=$TS ════════"
echo "issue: Igor-creato/deploy-cashback#1   container=$CONTAINER"
echo "── Решающие поля ──"
# Без jq (нет в образе) — грубый, но надёжный греп по плоским ключам.
for k in opcache_enabled cache_full restart_pending restart_in_progress \
         used_memory free_memory wasted_memory current_wasted_percentage \
         num_cached_scripts num_cached_keys max_cached_keys hits misses \
         oom_restarts hash_restarts manual_restarts start_time \
         last_restart_time opcache_hit_rate; do
  v="$(printf '%s' "$RAW" | grep -oE "\"$k\":[^,}]+" | head -1)"
  [ -n "$v" ] && echo "  $v"
done
echo "── Интерпретация ──"
echo "  oom/hash_restarts >0 и растут после релиза → restart-storm подтверждён."
echo "  cache_full=true / wasted% высокий / num_cached_keys≈max → SHM-давление"
echo "  (validate_timestamps=0 не выгружает старые записи при wp-admin ZIP)."
echo "── RAW opcache_get_status(false) ──"
printf '%s\n' "$RAW"
echo "════════════════════════════════════════════════════════"
echo
echo "Совет: сними ДО релиза и ПОВТОРНО сразу после wp-admin ZIP —" >&2
echo "рост *_restarts/last_restart_time = прямое доказательство." >&2
