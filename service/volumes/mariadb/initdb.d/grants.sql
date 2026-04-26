-- Cashback user — обычные права на свою БД
GRANT SUPER ON *.* TO 'cashback_user'@'%';

-- mysqld-exporter user — read-only для метрик.
-- Пароль подставляется через ALTER USER из install.sh после первого старта,
-- т.к. .sql в initdb.d не разворачивает env-vars.
CREATE USER IF NOT EXISTS 'exporter'@'%' IDENTIFIED BY 'changeme_set_by_install';
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'%';

FLUSH PRIVILEGES;
