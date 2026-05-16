#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# capture-fpm-usr2.sh — read-only улика prod PHP-FPM USR2 spawn-loop.
#
# Tracking: Igor-creato/deploy-cashback#1
#
# ЧТО ДЕЛАЕТ: арм'ит непрерывный захват логов/событий/переписи воркеров ДО
# graceful-reload, делает РОВНО ОДИН `docker kill -s USR2 wordpress`, ведёт
# съёмку через полное восстановление, затем строит компактный SUMMARY.txt.
#
# ПОЛНОСТЬЮ READ-ONLY относительно стэка:
#   - НЕ меняет конфиг, НЕ recreate/restart контейнер.
#   - Единственное мутирующее действие = ОДИН сигнал USR2 (тот же, что и
#     штатный deploy.yml плагина; санкционирован владельцем).
#   - Никаких apt-get/инсталляций в контейнер. Инструменты: docker
#     logs/events/stats/top + cgi-fcgi (уже в образе, Dockerfile:18,26).
#   - Снимает FPM-статус с ВЫДЕЛЕННОГО listener :9001 (pm.status_listen,
#     www.conf:31) — пул на :9000 НЕ трогается.
#   - Перепись процессов через `docker top` (ps на ХОСТЕ) — в образе нет
#     procps, поэтому in-container `ps` недоступен.
#
# ЗАПУСК (оператор, на ПРОД-хосте, окно низкого трафика):
#   bash service/scripts/diag/capture-fpm-usr2.sh
# По умолчанию скрипт сам шлёт ОДИН USR2 после явного подтверждения `yes`.
# Чтобы USR2 послали извне (напр. реальный релиз) — флаг --no-fire: скрипт
# армируется и ждёт, USR2 инициирует внешний процесс.
#
# ПОСЛЕ: вставить в чат СОДЕРЖИМОЕ `<OUTDIR>/SUMMARY.txt`. Сырые файлы
# остаются в OUTDIR — НЕ пересоздавать контейнер, пока не разобрали.
# ═══════════════════════════════════════════════════════════════════════════
set -u -o pipefail

CONTAINER="${CONTAINER:-wordpress}"
STATUS_PORT="${STATUS_PORT:-9001}"      # pm.status_listen (выделенный, не пул)
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-0.5}"   # сек между тиками сэмплера (~2 Гц)
MAX_CAPTURE_SECONDS="${MAX_CAPTURE_SECONDS:-300}"  # потолок всей съёмки
STABLE_SECONDS="${STABLE_SECONDS:-30}"  # «восстановлено» = тишина в логе N сек
FIRE_USR2=1
[ "${1:-}" = "--no-fire" ] && FIRE_USR2=0

TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUTDIR="${OUTDIR:-/tmp/fpm-usr2-$TS}"
mkdir -p "$OUTDIR" || { echo "FATAL: не создать $OUTDIR" >&2; exit 1; }

log()  { printf '%s %s\n' "$(date -u +%H:%M:%S.%3N)" "$*"; }
hr()   { printf -- '──────────────────────────────────────────────────────────\n'; }
nowns(){ date -u +%s.%N; }

# ── Preflight ──────────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || { echo "FATAL: docker не найден" >&2; exit 1; }
if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "FATAL: контейнер '$CONTAINER' не найден" >&2; exit 1
fi
if ! docker exec "$CONTAINER" sh -c 'command -v cgi-fcgi' >/dev/null 2>&1; then
  echo "WARN: cgi-fcgi не найден в контейнере — FPM-статус будет пропущен" >&2
  HAVE_FCGI=0
else
  HAVE_FCGI=1
fi

# ps-формат для docker top (ps на хосте; PID = ХОСТовые)
TOPFMT='-eww -o pid,ppid,lstart,etimes,stat,wchan:24,rss,cmd'
top_fpm() { docker top "$CONTAINER" $TOPFMT 2>/dev/null \
              | awk 'NR==1 || /php-fpm/'; }

fpm_status() {  # full+json со status-listener :9001 (не трогает пул)
  [ "$HAVE_FCGI" -eq 1 ] || { echo '{"_skipped":"no cgi-fcgi"}'; return; }
  docker exec "$CONTAINER" sh -c \
    'SCRIPT_NAME=/fpm-status SCRIPT_FILENAME=/fpm-status QUERY_STRING="full&json" REQUEST_METHOD=GET \
     cgi-fcgi -bind -connect 127.0.0.1:'"$STATUS_PORT"' 2>/dev/null' \
    | sed -n '/{/,$p'
}

MASTER_PID="$(docker exec "$CONTAINER" sh -c 'cat /proc/1/comm 2>/dev/null' \
              | grep -q php-fpm && docker top "$CONTAINER" -o pid,ppid,cmd 2>/dev/null \
              | awk '/php-fpm: master/{print $1; exit}')"
[ -n "${MASTER_PID:-}" ] || MASTER_PID="$(docker top "$CONTAINER" -o pid,ppid,cmd 2>/dev/null | awk '/php-fpm/ && $2==0 {print $1; exit}')"

# ── Снимок ПРЕД-состояния (отвечает Q1) ───────────────────────────────────
log "OUTDIR=$OUTDIR  CONTAINER=$CONTAINER  MASTER_PID(host)=${MASTER_PID:-?}"
{
  echo "# PRE-USR2 census  ts=$TS  container=$CONTAINER"
  echo "## docker inspect (RestartCount/StartedAt/Image)"
  docker inspect -f 'RestartCount={{.RestartCount}} StartedAt={{.State.StartedAt}} Image={{.Image}} Pid={{.State.Pid}}' "$CONTAINER"
  hr; echo "## php-fpm процессы (docker top, host PIDs, lstart/etimes/stat/wchan)"
  top_fpm
  hr; echo "## docker stats (snapshot)"
  docker stats --no-stream --format \
    'CPU={{.CPUPerc}} MEM={{.MemUsage}} PIDS={{.PIDs}}' "$CONTAINER"
  hr; echo "## FPM full status (listener :$STATUS_PORT, pre-USR2)"
  fpm_status
  hr; echo "## cgroup pids/memory (host view of container PID ${MASTER_PID:-?})"
  if [ -n "${MASTER_PID:-}" ]; then
    for f in /proc/"$MASTER_PID"/cgroup; do cat "$f" 2>/dev/null; done
    cat "/proc/${MASTER_PID}/limits" 2>/dev/null | grep -Ei 'processes|open files'
  fi
} > "$OUTDIR/pre-usr2.txt" 2>&1
log "pre-usr2.txt снят (Q1: см. возраст/состояние воркеров и FPM full-status)"

# ── Старт непрерывных стримов ДО USR2 ─────────────────────────────────────
# Критично: json-file ротация 10m×3 уничтожит улику на высокочастотном лупе;
# поэтому полный поток льём в файл с этого момента.
docker logs --tail 3000 --timestamps "$CONTAINER" > "$OUTDIR/fpm-pre.log" 2>&1 || true
( docker logs -f --since 0s --timestamps "$CONTAINER" ) > "$OUTDIR/fpm.log" 2>&1 &
LOGS_PID=$!
( docker events --filter "container=$CONTAINER" \
    --format '{{.Time}} {{.Status}} {{.Actor.Attributes.name}}' ) \
    > "$OUTDIR/events.log" 2>&1 &
EVENTS_PID=$!
cleanup() { kill "$LOGS_PID" "$EVENTS_PID" "${SAMP_PID:-}" 2>/dev/null; }
trap cleanup EXIT INT TERM
sleep 1
log "стримы запущены: docker logs -f → fpm.log, docker events → events.log"

# ── Сэмплер (фон): тики с меткой времени ──────────────────────────────────
SAMPLES="$OUTDIR/samples.tsv"
echo -e "epoch\tfpm_children\tstatus_oneline" > "$SAMPLES"
(
  end=$(( $(date +%s) + MAX_CAPTURE_SECONDS ))
  while [ "$(date +%s)" -lt "$end" ]; do
    e="$(nowns)"
    n="$(docker top "$CONTAINER" -o cmd 2>/dev/null | grep -c 'php-fpm' || echo 0)"
    s="$(fpm_status 2>/dev/null | tr -d '\n' \
          | grep -oE '"(active processes|idle processes|total processes|listen queue|max children reached|slow requests)":[0-9]+' \
          | paste -sd' ' - )"
    printf '%s\t%s\t%s\n' "$e" "$n" "${s:-na}" >> "$SAMPLES"
    sleep "$SAMPLE_INTERVAL"
  done
) &
SAMP_PID=$!
log "сэмплер армирован (interval=${SAMPLE_INTERVAL}s, cap=${MAX_CAPTURE_SECONDS}s)"

# ── Триггер USR2 (ровно один) ─────────────────────────────────────────────
T0="$(nowns)"; T0H="$(date -u +%H:%M:%S.%3N)"
if [ "$FIRE_USR2" -eq 1 ]; then
  echo
  echo ">>> Готов послать ОДИН 'docker kill -s USR2 $CONTAINER'."
  echo ">>> Это graceful-reload (тот же сигнал, что штатный deploy). Сайт"
  echo ">>> остаётся 200. Подтверди вводом 'yes' (любое другое — отмена):"
  read -r ans
  if [ "$ans" = "yes" ]; then
    T0="$(nowns)"; T0H="$(date -u +%H:%M:%S.%3N)"
    docker kill -s USR2 "$CONTAINER" >/dev/null \
      && log "USR2 ОТПРАВЛЕН в $T0H (T0)" \
      || { log "FATAL: docker kill -s USR2 не удался"; exit 1; }
  else
    log "USR2 ОТМЕНЁН оператором — захват остановлен, улики нет"
    exit 0
  fi
else
  log "режим --no-fire: жду внешний USR2. T0 определю по 'reloading' в логе."
fi
echo "$T0 $T0H" > "$OUTDIR/t0.txt"

# ── Ждать восстановления: тишина STABLE_SECONDS в логе по lifecycle-строкам ─
log "съёмка идёт; жду стабилизации (нет start/exit/reload ${STABLE_SECONDS}s)…"
deadline=$(( $(date +%s) + MAX_CAPTURE_SECONDS ))
last_evt=$(date +%s)
prev_lc=-1
while [ "$(date +%s)" -lt "$deadline" ]; do
  # «Тишина» = счётчик lifecycle-строк во ВСЁМ fpm.log перестал расти на
  # STABLE_SECONDS (старый вариант сравнивал tail-400 и при коротком логе
  # никогда не «затихал» → жёг весь MAX_CAPTURE_SECONDS).
  lc="$(grep -cE 'child [0-9]+ (started|exited)|reloading: execvp|ready to handle connections' \
        "$OUTDIR/fpm.log" 2>/dev/null)"; : "${lc:=0}"
  cur=$(date +%s)
  if [ "$lc" -ne "$prev_lc" ]; then
    prev_lc=$lc
    last_evt=$cur
  fi
  if [ $(( cur - last_evt )) -ge "$STABLE_SECONDS" ]; then
    log "lifecycle-строки не растут ${STABLE_SECONDS}s → восстановлено"
    break
  fi
  sleep 2
done
sleep 2
cleanup; trap - EXIT INT TERM
log "стримы остановлены"

# ── Пост-снимок ───────────────────────────────────────────────────────────
{
  echo "# POST census"
  top_fpm
  hr; docker stats --no-stream --format 'CPU={{.CPUPerc}} MEM={{.MemUsage}} PIDS={{.PIDs}}' "$CONTAINER"
  hr; fpm_status
} > "$OUTDIR/post.txt" 2>&1

# ── Анализ → SUMMARY.txt (компактно; ЭТО вставлять в чат) ──────────────────
SUM="$OUTDIR/SUMMARY.txt"
L="$OUTDIR/fpm.log"
# grep -c печатает 0 и при отсутствии совпадений (только код возврата=1),
# поэтому НЕ добавляем `|| echo 0` (давал дубль "0\n0"); страхуем ${:-0}.
exited_code="$(grep -cE 'exited with code'   "$L" 2>/dev/null)"; : "${exited_code:=0}"
exited_sig="$(grep -cE  'exited on signal'    "$L" 2>/dev/null)"; : "${exited_sig:=0}"
started_n="$(grep -cE   'child [0-9]+ started' "$L" 2>/dev/null)"; : "${started_n:=0}"
reload_ln="$(grep -nE   'reloading: execvp|reloading: master|Reloading' "$L" 2>/dev/null | head -3)"
ready_ln="$(grep -nE    'ready to handle connections' "$L" 2>/dev/null | tail -3)"
warn_ln="$(grep -nE     '\[WARNING\]|\[ERROR\]' "$L" 2>/dev/null | grep -vE 'child [0-9]+ exited (with code 0|on signal)' | head -20)"

# Гистограмма «после старта N сек» из строк exit (длительность жизни ребёнка)
life_hist="$(grep -oE 'after [0-9.]+ seconds from start' "$L" 2>/dev/null \
  | awk '{print $2}' \
  | awk '{ if($1<0.05)b="<50ms"; else if($1<0.5)b="50-500ms"; else if($1<5)b="0.5-5s"; else if($1<60)b="5-60s"; else b=">60s"; c[b]++ } END{ for(k in c) printf "  %-9s %d\n",k,c[k] }')"

# Спавн-rate по секундным бакетам (из RFC3339-меток docker logs --timestamps)
rate_top="$(grep -E 'child [0-9]+ started' "$L" 2>/dev/null \
  | awk '{print substr($1,1,19)}' | sort | uniq -c | sort -rn | head -5)"

# Жизнь самого старого pre-USR2 pool-воркера (кандидат «застрявший», Q1/Q3).
# TOPFMT: pid ppid lstart(5 ток.) etimes stat wchan rss cmd → etimes = поле 8.
oldest="$(grep -E 'php-fpm: pool' "$OUTDIR/pre-usr2.txt" 2>/dev/null \
  | sort -k8 -n 2>/dev/null | tail -1)"

{
  echo "════════ SUMMARY — prod PHP-FPM USR2 spawn-loop ════════"
  echo "issue: Igor-creato/deploy-cashback#1   capture: $TS"
  echo "OUTDIR(на сервере, не трогать контейнер!): $OUTDIR"
  echo "T0 (USR2): $(cat "$OUTDIR/t0.txt" 2>/dev/null)"
  hr
  echo "Q2 — причина смерти детей в логе:"
  echo "  'exited with code …'  : $exited_code   (добровольно / pm-accounting / max_requests)"
  echo "  'exited on signal …'  : $exited_sig    (master убил: graceful-drain / terminate_timeout)"
  echo "  'child … started'     : $started_n"
  echo "  → если code≫signal и max children reached растёт → pm-saturation при живой старой генерации"
  echo "  → если signal на ~120s → request_terminate_timeout/drain"
  hr
  echo "Q2 — длительность жизни умерших детей (after N seconds from start):"
  echo "${life_hist:-  (нет строк exit)}"
  hr
  echo "Спавн-rate (top секундные бакеты, 'child started' в сек):"
  echo "${rate_top:-  (нет)}"
  hr
  echo "Q1 — самый старый php-fpm воркер ПЕРЕД USR2 (etimes=4-е поле):"
  echo "  ${oldest:-  (не извлечён — см. pre-usr2.txt)}"
  echo "  (полная пред-перепись + FPM full-status: pre-usr2.txt)"
  hr
  echo "Reload-маркеры:"
  echo "${reload_ln:-  (нет 'reloading' — проверь fpm.log/ fpm-pre.log)}"
  echo "Last 'ready to handle connections':"
  echo "${ready_ln:-  (нет)}"
  hr
  echo "Q3 — окно лупа (из samples.tsv: total/active/listen queue/max children reached):"
  echo "  первые 3 тика:"; sed -n '2,4p' "$SAMPLES" 2>/dev/null | sed 's/^/    /'
  echo "  ... последние 3 тика:"; tail -3 "$SAMPLES" 2>/dev/null | sed 's/^/    /'
  echo "  (полная динамика — samples.tsv; пик 'max children reached' = saturation-сигнал)"
  hr
  echo "WARNING/ERROR (не штатные child-exit), до 20:"
  echo "${warn_ln:-  (нет — это сам по себе сигнал: дети молча exit 0)}"
  hr
  echo "POST-восстановление (число воркеров/статус): см. post.txt"
  echo "Файлы: pre-usr2.txt fpm-pre.log fpm.log events.log samples.tsv post.txt"
  echo "ДЕЙСТВИЕ: вставь этот SUMMARY в чат. Контейнер НЕ пересоздавать."
  echo "════════════════════════════════════════════════════════"
} > "$SUM"

cat "$SUM"
log "ГОТОВО. Вставь в чат: $SUM  (сырьё в $OUTDIR)"
