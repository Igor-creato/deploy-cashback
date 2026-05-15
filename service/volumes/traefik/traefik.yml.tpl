# ═══════════════════════════════════════════
# Traefik v3 — Optimized for low traffic (500–1000 req/day)
# ═══════════════════════════════════════════
#
# ШАБЛОН. Не редактируйте сгенерированный traefik.yml вручную — он в
# .gitignore и перезаписывается install.sh из этого .tpl через envsubst
# (подстановка переменной ACME_EMAIL; install.sh запрашивает её
# интерактивно либо берёт из окружения). Здесь намеренно НЕ пишем сам
# плейсхолдер в прозе — envsubst заменил бы и его.

entryPoints:
  web:
    address: ':80'
    http:
      encodedCharacters:
        allowEncodedSlash: false
        allowEncodedBackSlash: false
        allowEncodedNullCharacter: false
        allowEncodedSemicolon: false
        allowEncodedPercent: false
        allowEncodedQuestionMark: false
        allowEncodedHash: false
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true
  websecure:
    address: ':443'
    http:
      encodedCharacters:
        allowEncodedSlash: false
        allowEncodedBackSlash: false
        allowEncodedNullCharacter: false
        allowEncodedSemicolon: false
        allowEncodedPercent: false
        allowEncodedQuestionMark: false
        allowEncodedHash: false
      tls:
        certResolver: letsencrypt
    transport:
      respondingTimeouts:
        readTimeout: 300s
        writeTimeout: 300s
        idleTimeout: 120s
    forwardedHeaders:
      insecure: false
      # F-S1-012: trustedIPs сужены до фактически используемых диапазонов.
      # Docker по умолчанию использует 172.16-31.x.x (default bridge + custom
      # bridges); 10.0.0.0/8 и 192.168.0.0/16 не задействуются. Если кто-то
      # поднимет VPN/wireguard-туннель в эти диапазоны, он мог бы spoof'ить
      # X-Forwarded-For и обходить per-IP rate-limit / real-IP detection.
      trustedIPs:
        - '127.0.0.1/32'
        - '172.16.0.0/12'
  ping:
    address: ':8082'

providers:
  docker:
    endpoint: 'tcp://docker-socket-proxy:2375'
    exposedByDefault: false
    network: proxy
    watch: true
  file:
    filename: '/etc/traefik/config.yml'
    watch: true

api:
  dashboard: false
  insecure: false

# ── Главный лог Traefik: stderr → Docker json-file (ротация 10m×3) ──
log:
  level: WARN
  format: json

# ── ИЗМЕНЕНИЕ: accessLog отключён по умолчанию ──
# В минорной нагрузке (1k req/day) hit-by-hit access-log даёт I/O без пользы.
# Диагностика: Traefik 4xx/5xx и так попадают в основной log (level=WARN+).
# Если временно нужен accessLog (например — расследование инцидента),
# раскомментировать блок ниже и сделать `docker compose restart traefik`.
#
# accessLog:
#   filePath: /var/log/traefik/access.log
#   format: json
#   bufferingSize: 100
#   filters:
#     statusCodes:
#       - '500-599'      # сократил до 5xx — 4xx обычно noise (404 от ботов и т.п.)
#     retryAttempts: true
#     minDuration: '1s'   # повышен порог — фильтрует только реально медленные

certificatesResolvers:
  letsencrypt:
    acme:
      email: '${ACME_EMAIL}'
      storage: acme.json
      httpChallenge:
        entryPoint: web

ping:
  entryPoint: ping
