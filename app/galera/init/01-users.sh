#!/bin/bash
# Выполняется entrypoint'ом один раз, при инициализации пустого datadir.
# На galera-2/3 эти пользователи потом перезапишутся данными с galera-1 (SST).
set -e
mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" <<SQL
-- для SST (mariabackup на ноде-доноре), только локальный доступ
CREATE USER IF NOT EXISTS 'sst'@'localhost' IDENTIFIED BY '${SST_PASSWORD}';
GRANT RELOAD, PROCESS, LOCK TABLES, BINLOG MONITOR ON *.* TO 'sst'@'localhost';
-- для health-check HAProxy: без пароля и без прав, только проверка handshake
CREATE USER IF NOT EXISTS 'haproxy'@'%';
SQL
