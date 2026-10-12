#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

compose() {
    docker compose -f docker-compose.yml -f docker-compose.tls-local.yml "$@"
}

compose up -d --build --wait

root_cert="$(compose exec -T caddy-tls-local cat /data/caddy/pki/authorities/local/root.crt)"

echo
echo "Local TLS is up: https://localhost:8443"
if command -v openssl >/dev/null 2>&1; then
    printf '%s\n' "$root_cert" | openssl x509 -noout -subject -fingerprint -sha256
else
    echo "openssl not found; root certificate follows:"
    printf '%s\n' "$root_cert"
fi

status="$(curl -k -s -o /dev/null -w '%{http_code}' https://localhost:8443/health || true)"
echo "GET https://localhost:8443/health -> $status"
[ "$status" = "200" ]
