#!/bin/bash
# Обёртка над стандартным entrypoint MariaDB.
set -e

# 1. Пароль SST кладём в конфиг, а не в аргументы командной строки:
#    аргументы mariadbd попадают в логи и в список процессов.
if [ -n "${SST_PASSWORD:-}" ]; then
  umask 077
  printf '[mariadbd]\nwsrep_sst_auth=sst:%s\n' "$SST_PASSWORD" > /etc/mysql/conf.d/zz-sst-auth.cnf
  chown mysql:mysql /etc/mysql/conf.d/zz-sst-auth.cnf
  umask 022
fi

# 2. Bootstrap-логика для galera-1 (GALERA_BOOTSTRAP=1).
#    - Данных нет (первый запуск)            -> создаём новый кластер.
#    - Есть живые соседи (порт 4567 открыт)  -> присоединяемся к ним.
#      Так galera-1 после падения (chaos) возвращается в существующий кластер,
#      а не создаёт второй (split-brain).
#    - Соседей нет (холодный старт всего кластера, compose up / recreate)
#      -> galera-1 поднимает кластер заново. galera-2/3 зависят от galera-1
#      в compose, поэтому при compose up она всегда стартует первой и одна.
#      Компромисс: если после ухода galera-1 записи успели попасть на galera-2/3,
#      они будут потеряны. Запись идёт через HAProxy на galera-1, поэтому
#      обычно она и так самая актуальная.
GRASTATE=/var/lib/mysql/grastate.dat
PEERS="${GALERA_PEERS:-galera-2 galera-3}"

peer_alive() {
  for h in $PEERS; do
    if timeout 2 bash -c "</dev/tcp/$h/4567" 2>/dev/null; then
      echo "$h"; return 0
    fi
  done
  return 1
}

if [ "${GALERA_BOOTSTRAP:-0}" = "1" ]; then
  if [ ! -f "$GRASTATE" ]; then
    echo "[galera] no data yet: bootstrapping new cluster"
    set -- "$@" --wsrep-new-cluster
  elif PEER=$(peer_alive); then
    echo "[galera] peer $PEER is alive: joining existing cluster"
  else
    echo "[galera] no live peers: cold start, bootstrapping cluster from this node"
    sed -i 's/^safe_to_bootstrap: 0/safe_to_bootstrap: 1/' "$GRASTATE"
    set -- "$@" --wsrep-new-cluster
  fi
fi

exec docker-entrypoint.sh "$@"
