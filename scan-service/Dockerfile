FROM php:8.3-cli

WORKDIR /app
COPY . /app

# libpng-dev is gd's own dependency; libsqlite3-dev is pdo_sqlite's -
# docker-php-ext-install compiles both extensions from source against these
# headers, so both are required even though only libpng-dev was here before
# (confirmed failing to build without libsqlite3-dev - Mark, 2026-09-01).
# No --with-jpeg/libjpeg-dev: FloorPlanImageRenderer only ever calls
# imagepng(), never imagejpeg(), so there is nothing here that needs it.
# Acquire::Retries/Acquire::http::Timeout: apt's own fetch retries a
# dropped connection instead of failing the whole build on one bad request
# in the sequence - seen live on this machine's WSL2/Docker network (single
# requests to the same mirror/IPs always succeeded, only apt's multi-request
# fetch sequence inside the container timed out).
RUN apt-get update -o Acquire::Retries=5 -o Acquire::http::Timeout=30 \
    && apt-get install -y -o Acquire::Retries=5 -o Acquire::http::Timeout=30 --no-install-recommends libpng-dev libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/* \
    && docker-php-ext-install pdo_sqlite gd

EXPOSE 8089
ENV SCAN_SERVICE_DB_PATH=/app/data/scan_service.sqlite

# post_max_size raised above index.php's own MAX_REQUEST_BODY_BYTES cap
# (8MB) so PHP's own SAPI-level body-size enforcement — which runs before
# index.php's code and cannot be adjusted with ini_set() at request time —
# never fires ahead of our own check. Without this, a request just over the
# application cap trips PHP's default 8M post_max_size first instead, which
# emits a raw startup Warning (bypassing this app's set_exception_handler,
# since a native Warning is not a Throwable) and locks the HTTP status at
# 200 before index.php's own http_response_code(413) call ever runs. See
# scan-service/README.md's "Known limits" for the same note applied to the
# native PHP dev server invocation.
CMD ["php", "-d", "post_max_size=16M", "-d", "display_errors=0", "-S", "0.0.0.0:8089", "public/index.php"]
