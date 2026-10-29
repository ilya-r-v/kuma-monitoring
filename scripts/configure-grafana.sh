#!/bin/sh
# Настраивает Grafana через HTTP API: datasource Prometheus + дашборды из monitoring/grafana/dashboards.
# Идемпотентно: повторный запуск обновляет, а не дублирует.
set -eu

API="$GRAFANA_URL/api"
AUTH="$GRAFANA_USER:$GRAFANA_PASSWORD"

echo "waiting for grafana..."
for i in $(seq 1 30); do
  curl -fs "$API/health" >/dev/null && break
  sleep 2
done
curl -fs "$API/health" >/dev/null || { echo "ERROR: grafana is not ready"; exit 1; }

# url — адрес Prometheus с точки зрения Grafana (внутри сети kuma-net), а не с хоста
DS='{"name":"Prometheus","type":"prometheus","uid":"prometheus","access":"proxy","url":"http://prometheus:9090","isDefault":true}'

if curl -fs -u "$AUTH" "$API/datasources/uid/prometheus" >/dev/null; then
  curl -fsS -u "$AUTH" -X PUT -H 'Content-Type: application/json' -d "$DS" "$API/datasources/uid/prometheus" >/dev/null
  echo "datasource: updated"
else
  curl -fsS -u "$AUTH" -X POST -H 'Content-Type: application/json' -d "$DS" "$API/datasources" >/dev/null
  echo "datasource: created"
fi

for f in monitoring/grafana/dashboards/*.json; do
  jq '{dashboard: (. + {id: null}), overwrite: true}' "$f" \
    | curl -fsS -u "$AUTH" -X POST -H 'Content-Type: application/json' -d @- "$API/dashboards/db" \
    | jq -r '"dashboard: " + .url'
done