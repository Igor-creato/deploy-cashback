apiVersion: 1

# ─────────────────────────────────────────────
# Контакт для уведомлений — Email через Timeweb SMTP
# SMTP настраивается в секции environment сервиса grafana.
# Этот файл — шаблон. install.sh рендерит его в contact-points.yml
# через envsubst, подставляя ${ALERT_EMAIL} из .env.
# ─────────────────────────────────────────────
contactPoints:
  - orgId: 1
    name: Email
    receivers:
      - uid: email-receiver
        type: email
        settings:
          addresses: '${ALERT_EMAIL}'
          subject: |
            {{ if eq .Status "firing" }}🔴 [{{ .CommonLabels.severity }}] {{ else }}✅ RESOLVED: {{ end }}{{ .CommonLabels.alertname }}
          message: |
            {{ if eq .Status "firing" }}🔴 Проблема{{ else }}✅ Устранено{{ end }}

            Алерт: {{ .CommonLabels.alertname }}
            Severity: {{ .CommonLabels.severity }}
            {{ range .Alerts }}
            ─────────────────────────────────
            {{ if .Annotations.summary }}{{ .Annotations.summary }}{{ end }}
            {{ if .Labels.name }}Контейнер: {{ .Labels.name }}{{ end }}
            {{ if .Labels.instance }}Хост: {{ .Labels.instance }}{{ end }}
            Started: {{ .StartsAt }}
            {{ if .Annotations.description }}{{ .Annotations.description }}{{ end }}
            {{ end }}

# ─────────────────────────────────────────────
# Маршрутизация — все алерты идут на Email,
# но critical напоминают чаще, warning реже
# ─────────────────────────────────────────────
policies:
  - orgId: 1
    receiver: Email
    group_by: ['alertname', 'name']
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 4h
    routes:
      - receiver: Email
        matchers:
          - severity = critical
        group_wait: 10s
        group_interval: 2m
        repeat_interval: 1h
      - receiver: Email
        matchers:
          - severity = warning
        repeat_interval: 12h
