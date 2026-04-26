#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════
#  Grafana dashboards installer
#  Скачивает популярные борды с grafana.com, патчит datasource
#  под victoriametrics-uid и кладёт в volumes/grafana/dashboards/.
#  Идемпотентен — повторный запуск перекачивает свежие версии.
# ═══════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STACK_DIR="$(dirname "$SCRIPT_DIR")"
DEST_DIR="${STACK_DIR}/volumes/grafana/dashboards"
DS_UID="victoriametrics-uid"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

if ! command -v curl &>/dev/null; then
  echo "[ERROR] curl не найден"
  exit 1
fi

mkdir -p "${DEST_DIR}"

# ─── Список дашбордов ────────────────────────────────────
# Формат: "<id>:<revision>:<filename>:<description>"
# Revision = "latest" — скачивает текущую последнюю версию через API.
# Подобрано минимальное достаточное покрытие — без перекрытий.
DASHBOARDS=(
  "1860:latest:node-exporter-full.json:Node Exporter Full (CPU/RAM/диск/сеть/IO хоста)"
  "14282:latest:cadvisor-compute-resources.json:cAdvisor Compute Resources (контейнеры)"
  "14057:latest:mysql-overview.json:MySQL Overview (mysqld-exporter)"
  "763:latest:redis-dashboard.json:Redis Dashboard (redis-exporter)"
  "11074:latest:node-exporter-for-prometheus.json:Node Exporter / Prometheus alt"
)

# ─── Функция загрузки одной борды ────────────────────────
fetch_dashboard() {
  local id="$1"
  local rev="$2"
  local filename="$3"
  local description="$4"

  info "Загружаю #${id}: ${description}"

  # Если revision="latest" — спросить у API текущую версию
  if [[ "$rev" == "latest" ]]; then
    rev="$(curl -fsSL "https://grafana.com/api/dashboards/${id}" 2>/dev/null \
      | grep -oP '"revision":\s*\K[0-9]+' | head -1)"
    if [[ -z "$rev" ]]; then
      warn "Не удалось определить revision для #${id}, пропускаю"
      return 1
    fi
  fi

  local url="https://grafana.com/api/dashboards/${id}/revisions/${rev}/download"
  local tmp; tmp="$(mktemp)"

  if ! curl -fsSL "$url" -o "$tmp"; then
    warn "Не удалось скачать #${id} rev ${rev}"
    rm -f "$tmp"
    return 1
  fi

  # ─── Патчим datasource под наш UID ─────────────────────
  # Community-борды используют ${DS_PROMETHEUS} placeholder. Заменяем его
  # и убираем __inputs (чтобы Grafana не спрашивала datasource при импорте).
  python3 - "$tmp" "${DEST_DIR}/${filename}" "$DS_UID" <<'PYEOF'
import json, re, sys

src, dst, ds_uid = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as f:
    data = json.load(f)

# Снести __inputs (provisioning не использует prompt'ы)
data.pop("__inputs", None)
data.pop("__requires", None)
data.pop("__elements", None)

def patch(obj):
    if isinstance(obj, dict):
        # Подменить datasource: и строкой "${DS_PROMETHEUS}", и объектом {type, uid}
        if "datasource" in obj:
            ds = obj["datasource"]
            if isinstance(ds, str) and ("${DS_" in ds or ds == "prometheus" or ds == ""):
                obj["datasource"] = {"type": "prometheus", "uid": ds_uid}
            elif isinstance(ds, dict):
                ds["uid"] = ds_uid
                ds.setdefault("type", "prometheus")
        for v in obj.values():
            patch(v)
    elif isinstance(obj, list):
        for v in obj:
            patch(v)

patch(data)

# Уникальный uid дашборда (Grafana требует уникальности при provisioning)
if "uid" in data and data["uid"]:
    data["uid"] = data["uid"][:40]
else:
    data["uid"] = re.sub(r'[^a-z0-9]+', '-', dst.split('/')[-1].replace('.json',''))[:40]

# id всегда сбрасываем (provisioning сам управляет)
data["id"] = None

with open(dst, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
  rm -f "$tmp"
  log "Сохранён: ${filename}"
}

# ─── Проверка python3 ────────────────────────────────────
if ! command -v python3 &>/dev/null; then
  warn "python3 не найден, ставлю..."
  apt-get update -qq && apt-get install -y -qq python3
fi

# ─── Скачать все ─────────────────────────────────────────
for entry in "${DASHBOARDS[@]}"; do
  IFS=':' read -r id rev fname desc <<< "$entry"
  fetch_dashboard "$id" "$rev" "$fname" "$desc" || true
done

# ─── Дать Grafana прочитать ──────────────────────────────
chmod 755 "${DEST_DIR}"
chmod 644 "${DEST_DIR}"/*.json 2>/dev/null || true

# ─── Триггер на reload (если контейнер запущен) ──────────
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^grafana$'; then
  info "Grafana перечитает дашборды через ~30 секунд (updateIntervalSeconds)"
fi

echo ""
log "Готово. Дашборды лежат в: ${DEST_DIR}"
info "Открой Grafana → Dashboards → должны появиться:"
for entry in "${DASHBOARDS[@]}"; do
  IFS=':' read -r id rev fname desc <<< "$entry"
  echo "    • ${desc}"
done
