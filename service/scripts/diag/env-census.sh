#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# env-census.sh — read-only перепись ЭФФЕКТИВНОГО окружения/конфига для
# дифференциала прод↔staging (Igor-creato/deploy-cashback#1, вопрос Q4).
#
# Запускать на ОБЕИХ средах ОДНИМ И ТЕМ ЖЕ скриптом:
#   - прод: оператор на savelloclub.ru-хосте
#   - staging: Claude по SSH (5.35.124.64:56789) после восстановления ключа
#
# Идемпотентно, ничего не меняет. Печатает один компактный отчёт в stdout
# и в файл ENV-CENSUS-<host>-<ts>.txt. Вставлять в чат вывод целиком.
#
# Смысл: статические файлы стэка git-идентичны прод↔staging, поэтому ищем
# различие в ЭФФЕКТИВНОМ слитом конфиге php-fpm (все .d-фрагменты + [global]),
# app-слое (drop-ins/.user.ini/auto_prepend) и host/cgroup-окружении.
# ═══════════════════════════════════════════════════════════════════════════
set -u -o pipefail

CONTAINER="${CONTAINER:-wordpress}"
HOSTLBL="${HOSTLBL:-$(hostname 2>/dev/null || echo unknown)}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${OUT:-/tmp/ENV-CENSUS-${HOSTLBL}-${TS}.txt}"

hr(){ printf -- '──────────── %s ────────────\n' "${1:-}"; }
dex(){ docker exec "$CONTAINER" sh -c "$1" 2>&1; }

command -v docker >/dev/null 2>&1 || { echo "FATAL: docker нет" >&2; exit 1; }
docker inspect "$CONTAINER" >/dev/null 2>&1 || { echo "FATAL: нет контейнера $CONTAINER" >&2; exit 1; }

{
echo "════════ ENV CENSUS  host=$HOSTLBL  ts=$TS  container=$CONTAINER ════════"

hr "container identity"
docker inspect -f 'Image={{.Image}}
ImageName={{.Config.Image}}
StartedAt={{.State.StartedAt}}
RestartCount={{.RestartCount}}' "$CONTAINER"

hr "php-fpm -tt  (ЭФФЕКТИВНЫЙ слитый конфиг: все .d + [global])"
# -tt печатает полностью разрешённый конфиг в stderr. Вытаскиваем ключевое
# целиком + явный фокус на дискриминаторах.
dex 'php-fpm -tt 2>&1'

hr "[global] / pool дискриминаторы (из -tt выше, продублировано грепом)"
dex 'php-fpm -tt 2>&1 | grep -iE "emergency_restart_threshold|emergency_restart_interval|process_control_timeout|daemonize|pm |pm\.|request_terminate_timeout|request_slowlog_timeout|max_requests|status_listen|listen ="'

hr "php -i — opcache / auto_prepend / user_ini / disable_functions / SAPI"
dex 'php -v; php -i 2>/dev/null | grep -iE "^(opcache\.|auto_prepend_file|auto_append_file|user_ini\.|disable_functions|max_execution_time|memory_limit) |Server API|Loaded Configuration|Scan this dir|opcache.jit|opcache.preload"'

hr "php -m  (загруженные расширения — порядок/набор)"
dex 'php -m | tr "\n" " "; echo'

hr "/usr/local/etc/php-fpm.d  (файлы + sha256 — что реально мёржится)"
dex 'ls -la /usr/local/etc/php-fpm.d/ ; echo "---sha256---" ; (cd /usr/local/etc/php-fpm.d && sha256sum * 2>/dev/null)'
hr "/usr/local/etc/php-fpm.conf + conf.d sha256"
dex 'sha256sum /usr/local/etc/php-fpm.conf 2>/dev/null; ls -la /usr/local/etc/php/conf.d/ ; (cd /usr/local/etc/php/conf.d && sha256sum * 2>/dev/null)'

hr "webroot drop-ins / .user.ini / mu-plugins / версия cashback"
dex 'cd /var/www/html/wp-content 2>/dev/null && {
  for f in object-cache.php advanced-cache.php db.php; do
    if [ -e "$f" ]; then printf "%-20s present  " "$f"; sha256sum "$f"; else echo "$f absent"; fi
  done
  echo "--- .user.ini под webroot ---"; find /var/www/html -maxdepth 3 -name ".user.ini" -exec sh -c "echo {}; cat {}" \; 2>/dev/null | head -40
  echo "--- mu-plugins ---"; ls -la mu-plugins 2>/dev/null
  echo "--- cashback версия ---"; grep -aoE "Version:[ ]*[0-9][0-9.]*" plugins/*ashback*/*.php 2>/dev/null | head -3
}'

hr "Action Scheduler — глубина очереди (контекст застрявшего as_async, Q1)"
dex 'wp --allow-root action-scheduler status 2>/dev/null || echo "(wp/AS недоступен — пропуск)"'

hr "HOST: ядро / docker / cpu"
uname -a
docker version --format 'docker {{.Server.Version}} api {{.Server.APIVersion}}' 2>/dev/null
echo "nproc=$(nproc 2>/dev/null)  load=$(cat /proc/loadavg 2>/dev/null)"

hr "HOST: cgroup лимиты контейнера (pids/memory) + OOM"
CPID="$(docker inspect -f '{{.State.Pid}}' "$CONTAINER" 2>/dev/null)"
if [ -n "${CPID:-}" ] && [ -r "/proc/$CPID/cgroup" ]; then
  echo "container host pid=$CPID  cgroup:"; cat "/proc/$CPID/cgroup" 2>/dev/null
  CG="/sys/fs/cgroup$(awk -F: '/^0:/{print $3}' /proc/$CPID/cgroup 2>/dev/null)"
  for k in pids.max pids.current memory.max memory.current memory.events; do
    [ -r "$CG/$k" ] && { printf '%-16s ' "$k"; tr "\n" " " < "$CG/$k"; echo; }
  done
fi
echo "--- dmesg OOM/killed (last 10) ---"
( dmesg 2>/dev/null || true ) | grep -iE 'oom|killed process' | tail -10 || echo "(dmesg недоступен/чисто)"

echo "════════ END ENV CENSUS  host=$HOSTLBL ════════"
} | tee "$OUT"

echo
echo "Записано: $OUT  — вставь содержимое в чат (для diff прод↔staging)." >&2
