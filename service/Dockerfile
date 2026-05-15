# F-S1-004: digest-pinned. Update flow: `docker pull wordpress:6.9.4-php8.4-fpm`
# затем подставить новый digest сюда.
FROM wordpress:6.9.4-php8.4-fpm@sha256:de6aeca1df3cb9cafb9b5b99f6435a05ba7f7640cae01d3b032a312203c029c3

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

# ── PHP-FPM: убрать дублирующий дефолтный pool базового образа ──
# Инцидент 2026-05-16 (прод savelloclub.ru): базовый www.conf образа
# (полный [www], listen=9000) сосуществовал с нашим zz-www.conf
# (volumes/php-config/www.conf, listen=0.0.0.0:9000). При старте
# контейнера фрагменты [www] сливались в один рабочий пул, но
# `docker kill -s USR2 wordpress` (graceful reload из deploy.yml плагина)
# этот многофайловый layout не переживал: воркеры не биндились → выходили
# code 0 за ~8мс → master бесконечно их респаунил (~120/сек), флуд лога.
# Оставляем официальные docker.conf / zz-docker.conf (только [global] +
# минимальные [www]-фрагменты, задуманы для слияния). Полный пул теперь
# определяется ТОЛЬКО zz-www.conf → USR2-reload снова безопасен.
RUN rm -f /usr/local/etc/php-fpm.d/www.conf \
          /usr/local/etc/php-fpm.d/www.conf.default

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
# Доставляем с GitHub Raw, при недоступности (DNS-сбой, 5xx, rate limit)
# делаем 3 повторных попытки с paused, затем фоллбэк на S3-mirror проекта
# wp-cli. Это additive: при штатном GitHub поведение прежнее, fallback
# только спасает голую сборку на сервере без зеркала docker hub.
RUN set -eux; \
    ok=0; \
    for i in 1 2 3; do \
      curl -fsSL --retry 3 --retry-delay 2 -o /usr/local/bin/wp \
        https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
        && ok=1 && break; \
      sleep 5; \
    done; \
    if [ "$ok" -ne 1 ]; then \
      curl -fsSL --retry 3 --retry-delay 2 -o /usr/local/bin/wp \
        https://wp-cli-builds.s3.amazonaws.com/wp-cli-latest-phar; \
    fi; \
    chmod +x /usr/local/bin/wp; \
    /usr/local/bin/wp --info --allow-root >/dev/null

ENTRYPOINT ["/usr/local/bin/docker-entrypoint-msmtp.sh"]
CMD ["php-fpm"]