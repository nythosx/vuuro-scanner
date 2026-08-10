FROM php:8.3-cli

WORKDIR /app
COPY . /app

RUN docker-php-ext-install pdo_sqlite

EXPOSE 8089
ENV SCAN_SERVICE_DB_PATH=/app/data/scan_service.sqlite

CMD ["php", "-S", "0.0.0.0:8089", "public/index.php"]
