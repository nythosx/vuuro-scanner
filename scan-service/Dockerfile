FROM dunglas/frankenphp:1-php8.3

WORKDIR /app

RUN install-php-extensions pdo_sqlite gd

ARG TARGETARCH
ARG KTX_VERSION=4.3.2
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
        amd64) ktx_arch=x86_64; ktx_sha=fa0670f157b77bc67e2da00fb4825a2df69a1a0ed12058626c9852dd23b90f07 ;; \
        arm64) ktx_arch=arm64; ktx_sha=1e6e5ea7d9b8a47c876365c7adc9ce36df2c9531df8fb425b2a0ef035e9977eb ;; \
        *) echo "No KTX-Software build for ${TARGETARCH}"; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/ktx.deb "https://github.com/KhronosGroup/KTX-Software/releases/download/v${KTX_VERSION}/KTX-Software-${KTX_VERSION}-Linux-${ktx_arch}.deb"; \
    echo "${ktx_sha}  /tmp/ktx.deb" | sha256sum -c -; \
    dpkg -i /tmp/ktx.deb; \
    rm /tmp/ktx.deb; \
    ldconfig; \
    toktx --version

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
