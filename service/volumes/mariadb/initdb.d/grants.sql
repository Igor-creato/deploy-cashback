-- Cashback user — права только на свою БД (без SUPER на *.*).
-- WP/Woo не нуждаются в SUPER; убрав его, ограничиваем impact от SQLi/RCE
-- в любом WP-плагине: атакующий не сможет SET GLOBAL, LOAD DATA LOCAL INFILE,
-- KILL чужие connections и т.д.
GRANT ALL PRIVILEGES ON cashback_db.* TO 'cashback_user'@'%';

-- mysqld-exporter user создаётся СКРИПТОМ setup-mariadb-users.sh после
-- первого старта MariaDB (там разворачивается env-var с реальным паролем).
-- В initdb.d НЕ создаём — иначе на ~90 сек после первого старта существовал бы
-- пользователь с предсказуемым паролем 'changeme_set_by_install' и SELECT *.*.

FLUSH PRIVILEGES;
