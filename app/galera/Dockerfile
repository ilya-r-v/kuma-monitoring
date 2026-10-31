FROM mariadb:11.4
COPY --chmod=644 galera.cnf /etc/mysql/conf.d/galera.cnf
COPY --chmod=755 galera-entrypoint.sh /usr/local/bin/galera-entrypoint.sh
COPY --chmod=755 init/ /docker-entrypoint-initdb.d/
ENTRYPOINT ["galera-entrypoint.sh"]
CMD ["mariadbd"]
