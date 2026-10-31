#!/bin/sh
# Chaos-тест: SIGKILL главному процессу контейнера (имитация падения).
# Проверяет: 1) Docker поднял контейнер (restart policy),
#            2) мониторинг зафиксировал падение и/или перезапуск.
set -eu
PROM="$PROMETHEUS_URL"

case "$TARGET" in
  mariadb)     METRIC='mysql_up' ;;
  uptime-kuma) METRIC='probe_success{job="blackbox-http"}' ;;
  *) echo "unknown target: $TARGET (mariadb | uptime-kuma)"; exit 1 ;;
esac

# сколько разных значений restartcount видел мониторинг за час (растёт при каждом автоперезапуске)
RC_METRIC="count(count by (container_label_restartcount) (last_over_time(container_start_time_seconds{name=\"$TARGET\"}[1h]))) or vector(0)"

q() { curl -fsG "$PROM/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // "none"'; }

# wait_for <PromQL> <значение> <таймаут>: печатает, через сколько секунд дождались
wait_for() {
  t=0
  while [ $t -lt "$3" ]; do
    [ "$(q "$1")" = "$2" ] && { echo "$t"; return 0; }
    sleep 1; t=$((t+1))
  done
  return 1
}

echo "[1/6] baseline: $METRIC = $(q "$METRIC")"
[ "$(q "$METRIC")" = "1" ] || { echo "target is not healthy before test, abort"; exit 1; }

RESTARTS_BEFORE=$(docker inspect -f '{{.RestartCount}}' "$TARGET")
RC_BEFORE=$(q "$RC_METRIC")
PID=$(docker inspect -f '{{.State.Pid}}' "$TARGET")

echo "[2/6] crash: SIGKILL to $TARGET main process (host pid $PID)"
docker run --rm --pid=host alpine:3.20 kill -9 "$PID"

echo "[3/6] waiting for monitoring to detect DOWN..."
if T=$(wait_for "$METRIC" 0 15); then
  echo "      DOWN detected after ${T}s"
else
  echo "      DOWN not caught: outage shorter than scrape interval (5s)"
fi

echo "[4/6] waiting for recovery..."
T=$(wait_for "$METRIC" 1 180) || { echo "FAIL: $TARGET did not recover in 180s"; exit 1; }
echo "      UP again after ${T}s"

echo "[5/6] waiting for monitoring to register the restart (cAdvisor restartcount)..."
t=0; RC_AFTER="$RC_BEFORE"
while [ $t -lt 60 ] && [ "$RC_AFTER" -le "$RC_BEFORE" ]; do
  sleep 2; t=$((t+2)); RC_AFTER=$(q "$RC_METRIC")
done
if [ "$RC_AFTER" -gt "$RC_BEFORE" ]; then
  echo "      restart registered by monitoring ($RC_BEFORE -> $RC_AFTER restart generations in 1h)"
else
  echo "FAIL: monitoring did not register the restart"; exit 1
fi

RESTARTS_AFTER=$(docker inspect -f '{{.RestartCount}}' "$TARGET")
echo "[6/6] docker restart count: $RESTARTS_BEFORE -> $RESTARTS_AFTER"
if [ "$RESTARTS_AFTER" -gt "$RESTARTS_BEFORE" ]; then
  echo "CHAOS TEST PASSED"
else
  echo "FAIL: container was not restarted by docker"; exit 1
fi