#!/bin/sh
# Проверяет весь контур: таргеты Prometheus, MariaDB, Uptime Kuma, cAdvisor, Grafana.
set -u

PROM="$PROMETHEUS_URL"
API="$GRAFANA_URL/api"
AUTH="$GRAFANA_USER:$GRAFANA_PASSWORD"
FAILED=0

q() {
  curl -fsG "$PROM/api/v1/query" --data-urlencode "query=$1" \
    | jq -r '.data.result[0].value[1] // "none"'
}

# check <название> <PromQL> <ожидаемое значение>: ждёт до 60 с
check() {
  i=0
  while [ $i -lt 20 ]; do
    got=$(q "$2")
    if [ "$got" = "$3" ]; then echo "OK    $1"; return 0; fi
    i=$((i+1)); sleep 3
  done
  echo "FAIL  $1 (got: $got, want: $3)"; FAILED=1
}

check "prometheus: 5 targets"         'count(up)' 5
check "prometheus: no targets down"   'count(up == 0) or vector(0)' 0
check "mariadb: mysql_up"             'mysql_up' 1
check "uptime-kuma: http probe"       'probe_success{job="blackbox-http"}' 1
check "cadvisor: stack containers"    'count(container_memory_working_set_bytes{container_label_com_docker_compose_project="kuma-app"}) > bool 0' 1

if curl -fs -u "$AUTH" "$API/datasources/uid/prometheus/health" | jq -e '.status == "OK"' >/dev/null; then
  echo "OK    grafana: datasource prometheus"
else
  echo "FAIL  grafana: datasource prometheus"; FAILED=1
fi

if curl -fs -u "$AUTH" "$API/dashboards/uid/kuma-overview" >/dev/null; then
  echo "OK    grafana: dashboard kuma-overview"
else
  echo "FAIL  grafana: dashboard kuma-overview"; FAILED=1
fi

if [ $FAILED -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; exit 1; fi