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

# ── WP-CLI (для host-cron и администрирования) ──
RUN curl -fsSL -o /usr/local/bin/wp \
      https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
 && chmod +x /usr/local/bin/wp \
 && /usr/local/bin/wp --info --allow-root >/dev/null

ENTRYPOINT ["/usr/local/bin/docker-entrypoint-msmtp.sh"]
CMD ["php-fpm"]