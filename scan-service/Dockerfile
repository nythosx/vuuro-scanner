FROM php:8.3-cli

WORKDIR /app
COPY . /app

RUN sed -i 's/http:\/\/deb.debian.org/https:\/\/deb.debian.org/g' /etc/apt/sources.list.d/*.sources 2>/dev/null; \
    sed -i 's/http:\/\/deb.debian.org/https:\/\/deb.debian.org/g' /etc/apt/sources.list 2>/dev/null; \
    apt-get update -o Acquire::Retries=5 -o Acquire::http::Timeout=30 \
    && apt-get install -y -o Acquire::Retries=5 -o Acquire::http::Timeout=30 --no-install-recommends libpng-dev libjpeg62-turbo-dev libfreetype6-dev libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/* \
    && docker-php-ext-configure gd --with-jpeg --with-freetype \
    && docker-php-ext-install pdo_sqlite gd

EXPOSE 8089
ENV SCAN_SERVICE_DB_PATH=/app/data/scan_service.sqlite

CMD ["php", "-d", "post_max_size=30M", "-d", "upload_max_filesize=26M", "-d", "display_errors=0", "-S", "0.0.0.0:8089", "public/index.php"]
