#!/bin/sh
# Обёртка над `dagger call`: загружает пароли из app/.env и monitoring/.env
# и подставляет нужные аргументы для каждой функции модуля.
# Пароли передаются в Dagger как секреты (env://...), в логи они не попадают.
#
# Использование: ./scripts/dagger-call.sh <deploy-app|deploy-monitoring|configure-grafana|validate|deploy-all|chaos> [доп. аргументы]
set -eu
cd "$(dirname "$0")/.."

for f in app/.env monitoring/.env; do
  [ -f "$f" ] || { echo "ERROR: $f not found, copy it from $f.example"; exit 1; }
done
set -a; . ./app/.env; . ./monitoring/.env; set +a

SOCK="--sock=/var/run/docker.sock"
PROM="--prometheus=tcp://localhost:9090"
GRAF="--grafana=tcp://localhost:3000"
GPW="--grafana-password=env://GRAFANA_ADMIN_PASSWORD"
DB="--db-root-password=env://DB_ROOT_PASSWORD --db-password=env://DB_PASSWORD --sst-password=env://SST_PASSWORD"
EXP="--exporter-password=env://EXPORTER_DB_PASSWORD"

FN="${1:-}"; [ $# -gt 0 ] && shift
case "$FN" in
  deploy-app)        exec dagger call deploy-app $SOCK $DB $EXP "$@" ;;
  deploy-monitoring) exec dagger call deploy-monitoring $SOCK $GPW $EXP "$@" ;;
  configure-grafana) exec dagger call configure-grafana $GRAF $GPW "$@" ;;
  validate)          exec dagger call validate $PROM $GRAF $GPW "$@" ;;
  deploy-all)        exec dagger call deploy-all $SOCK $PROM $GRAF $DB $EXP $GPW "$@" ;;
  chaos)             exec dagger call chaos $SOCK $PROM "$@" ;;
  *) echo "usage: $0 <deploy-app|deploy-monitoring|configure-grafana|validate|deploy-all|chaos> [args]"; exit 1 ;;
esac
