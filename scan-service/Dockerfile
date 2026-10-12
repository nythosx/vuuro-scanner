FROM dunglas/frankenphp:1-php8.3

WORKDIR /app

RUN install-php-extensions pdo_sqlite gd

RUN { \
        echo 'post_max_size=30M'; \
        echo 'upload_max_filesize=26M'; \
        echo 'display_errors=0'; \
    } > /usr/local/etc/php/conf.d/scan-service.ini

COPY . /app
COPY docker/frankenphp/Caddyfile /etc/frankenphp/Caddyfile

EXPOSE 8089
ENV SCAN_SERVICE_DB_PATH=/app/data/scan_service.sqlite

CMD ["frankenphp", "run", "--config", "/etc/frankenphp/Caddyfile"]
