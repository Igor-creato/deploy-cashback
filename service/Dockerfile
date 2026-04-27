FROM wordpress:6.9.4-php8.4-fpm

RUN apt-get update && apt-get install -y --no-install-recommends \
    msmtp \
    msmtp-mta \
    && rm -rf /var/lib/apt/lists/*

RUN echo "sendmail_path = \"/usr/bin/msmtp -t\"" > /usr/local/etc/php/conf.d/mail.ini

# Копируем ВАШ файл
COPY docker-entrypoint-msmtp.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint-msmtp.sh

RUN echo '#!/bin/sh\n\
    if nc -z localhost 9000; then\n\
    SCRIPT_NAME=/fpm-status SCRIPT_FILENAME=/fpm-status QUERY_STRING=json REQUEST_METHOD=GET cgi-fcgi -bind -connect localhost:9000 2>/dev/null | grep -q "pool.*www"\n\
    exit $?\n\
    else\n\
    exit 1\n\
    fi' > /usr/local/bin/php-fpm-healthcheck && \
    chmod +x /usr/local/bin/php-fpm-healthcheck

RUN apt-get update && apt-get install -y --no-install-recommends \
    libfcgi-bin \
    netcat-openbsd \
    less \
    && rm -rf /var/lib/apt/lists/*

# ── getaddrinfo: предпочитать IPv4 ──
# Контейнер сидит в bridge-сети без IPv6-egress, но DNS отдаёт AAAA первым.
# PHP-streams (fsockopen/stream_socket_client) не умеют Happy Eyeballs и
# зависают на default_socket_timeout=30s, пытаясь достучаться до AAAA.
# Эта строка переопределяет приоритет в getaddrinfo: IPv4-маппированные
# адреса получают вес 100 и идут первыми.
RUN printf 'precedence ::ffff:0:0/96 100\n' >> /etc/gai.conf

# ── PhpRedis (нативный клиент Redis) ──
# Без него Redis Object Cache откатывается на Predis (PHP-эмуляция протокола),
# что даёт ×5–×10 латентность на каждое обращение к Redis. На WooCommerce
# критично: десятки тысяч ops/req. Версия 6.2.0 — последний стабильный
# релиз, совместимый с PHP 8.4. $PHPIZE_DEPS ставим временно и удаляем
# после сборки расширения, чтобы не раздувать финальный образ.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends $PHPIZE_DEPS; \
    pecl install redis-6.2.0; \
    docker-php-ext-enable redis; \
    apt-get purge -y --auto-remove $PHPIZE_DEPS; \
    rm -rf /var/lib/apt/lists/* /tmp/pear

# ── WP-CLI (для host-cron и администрирования) ──
RUN curl -fsSL -o /usr/local/bin/wp \
      https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
 && chmod +x /usr/local/bin/wp \
 && /usr/local/bin/wp --info --allow-root >/dev/null

ENTRYPOINT ["/usr/local/bin/docker-entrypoint-msmtp.sh"]
CMD ["php-fpm"]