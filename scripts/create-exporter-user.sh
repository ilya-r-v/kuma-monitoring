#!/bin/sh
# Идемпотентно создаёт пользователя для mysqld_exporter.
# Создаём на galera-1: Galera реплицирует CREATE USER/GRANT на все ноды кластера.
# Пароль приходит в EXP_PW и передаётся в MariaDB через stdin, в аргументы команды он не попадает.
set -eu
docker exec -i galera-1 sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"' <<SQL
CREATE USER IF NOT EXISTS 'exporter'@'%' IDENTIFIED BY '${EXP_PW}' WITH MAX_USER_CONNECTIONS 3;
ALTER USER 'exporter'@'%' IDENTIFIED BY '${EXP_PW}';
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'%';
SQL
echo "exporter user ready"
