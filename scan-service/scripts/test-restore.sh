#!/bin/sh
set -eu

export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
source_dir="$(pwd)"

suffix="$$"
project="vuuro-restore-test-$suffix"
network="vuuro-restore-test-$suffix"
s3server="vuuro-restore-s3-$suffix"
port="${RESTORE_TEST_PORT:-18089}"
base_url="http://127.0.0.1:$port"
work="$(mktemp -d)"
svc="$work/svc"
failures=0
checks=0

SCAN_SERVICE_ADMIN_API_KEY="restore-test-admin-$suffix-0123456789abcdef"
SCAN_SERVICE_APP_KEY="restore-test-app-$suffix-0123456789abcdef"
SCAN_SERVICE_EXPORT_SECRET="restore-test-export-$suffix-0123456789abcdef"
export SCAN_SERVICE_ADMIN_API_KEY SCAN_SERVICE_APP_KEY SCAN_SERVICE_EXPORT_SECRET

real_data_before="$(ls -A "$source_dir/data" 2>/dev/null)"
mkdir -p "$svc" "$work/bin"
tar --exclude=./data --exclude=./.env --exclude='./*.log' -cf - . | tar -xf - -C "$svc"
mkdir -p "$svc/data"
if [ -n "${RESTORE_TEST_BASE_IMAGE:-}" ]; then
    sed -e "s#^FROM .*#FROM $RESTORE_TEST_BASE_IMAGE#" \
        -e 's#^RUN install-php-extensions .*#RUN rm -rf /app/* /app/.[!.]*#' Dockerfile > "$svc/Dockerfile"
    echo "building on $RESTORE_TEST_BASE_IMAGE instead of pulling the base image"
fi
svc_mount="$(cd "$svc" && (pwd -W 2>/dev/null || pwd))"
work_native="$(cd "$work" && (pwd -W 2>/dev/null || pwd))"
cat > "$svc/docker-compose.restore-test.yml" <<EOF
services:
  scan-service:
    ports: !override ["127.0.0.1:$port:8089"]
EOF
compose="docker compose -p $project -f docker-compose.yml -f docker-compose.restore-test.yml"

cleanup() {
    (cd "$svc" && $compose down -v --rmi local >/dev/null 2>&1) || true
    docker rm -f "$s3server" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT INT TERM

both_set() {
    [ -n "$1" ] && [ -n "$2" ]
}

check() {
    label="$1"
    shift
    checks=$((checks + 1))
    if "$@"; then
        echo "  [PASS] $label"
    else
        failures=$((failures + 1))
        echo "  [FAIL] $label"
    fi
}

rclone_env() {
    printf '%s\n' \
        -e RCLONE_CONFIG_TEST_TYPE=s3 \
        -e RCLONE_CONFIG_TEST_PROVIDER=Rclone \
        -e RCLONE_CONFIG_TEST_ACCESS_KEY_ID=vuurotest \
        -e RCLONE_CONFIG_TEST_SECRET_ACCESS_KEY=vuurotestsecret \
        -e RCLONE_CONFIG_TEST_ENDPOINT=http://"$s3server":9000 \
        -e RCLONE_CONFIG=/dev/null
}

cat > "$work/bin/rclone" <<EOF
#!/bin/sh
exec docker run --rm --network "$network" $(rclone_env | tr '\n' ' ') -v "$svc_mount/data:$svc/data" rclone/rclone:latest "\$@"
EOF
chmod +x "$work/bin/rclone"

json_field() {
    php -r '$j = json_decode(stream_get_contents(STDIN), true); $v = $j; foreach (explode(".", $argv[1]) as $k) { $v = is_array($v) ? ($v[$k] ?? null) : null; } echo is_array($v) ? count($v) : (string) $v;' "$1"
}

api() {
    method="$1"
    path="$2"
    shift 2
    curl -s -X "$method" "$base_url$path" -H "X-Scan-Access-Token: ${token:-}" "$@"
}

status_of() {
    curl -s -o /dev/null -w '%{http_code}' "$base_url$1" -H "X-Scan-Access-Token: $token"
}

wait_healthy() {
    container="$($compose ps -q scan-service)"
    tries=0
    while [ "$tries" -lt 60 ]; do
        [ "$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || true)" = "healthy" ] && return 0
        tries=$((tries + 1))
        sleep 2
    done
    return 1
}

docker network create "$network" >/dev/null
docker run -d --name "$s3server" --network "$network" \
    rclone/rclone:latest serve s3 --addr :9000 --auth-key vuurotest,vuurotestsecret /data >/dev/null

cd "$svc"
echo "== Throwaway stack $project on port $port =="
$compose up -d --build >/dev/null 2>&1 || { echo "could not start the stack"; $compose logs scan-service | tail -20; exit 1; }
check "the throwaway stack becomes healthy" wait_healthy

echo "== A session with rooms, a note and a photo =="
created="$(curl -s -X POST "$base_url/scan-sessions" -H 'Content-Type: application/json' -H "X-Scan-App-Key: $SCAN_SERVICE_APP_KEY" \
    -d "{\"property_id\":\"prop-restore-$suffix\",\"unit_id\":\"unit-restore-$suffix\",\"organisation_id\":\"org-restore-$suffix\",\"purpose\":\"check_in\",\"occupied\":false}")"
session_id="$(printf '%s' "$created" | json_field id)"
token="$(printf '%s' "$created" | json_field access_token)"
check "the session is created with the app key" both_set "$session_id" "$token"
[ -n "$session_id" ] || { echo "$created"; exit 1; }

capture='{"floor":"0","raw_capture":{"floors":[{"identifier":"floor-restore","category":"floor","confidence":"high","polygonCorners":[[0,0,0],[4,0,0],[4,0,3],[0,0,3]]}],"walls":[{"identifier":"w1","category":"wall","confidence":"high","dimensions":[4,2.6,0.1]}],"doors":[],"windows":[],"openings":[],"objects":[]}}'
api POST "/scan-sessions/$session_id/capture" -H 'Content-Type: application/json' -d "$capture" >/dev/null
rooms_before="$(api POST "/scan-sessions/$session_id/capture" -H 'Content-Type: application/json' -d "$capture" | json_field rooms)"
check "two rooms are captured (got $rooms_before)" [ "$rooms_before" = "2" ]

note_text="Restore test note, vochtige hoek in de slaapkamer"
note="$(api POST "/scan-sessions/$session_id/notes" -H 'Content-Type: application/json' -d "{\"text\":\"$note_text\"}")"
check "the note is saved" [ "$(printf '%s' "$note" | json_field notes)" = "1" ]

printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==' | base64 -d > "$work/photo.png"
upload="$(api POST "/scan-sessions/$session_id/photo-uploads" -F "photo=@$work_native/photo.png;type=image/png")"
photo_url="$(printf '%s' "$upload" | json_field url)"
photo_name="${photo_url##*/}"
check "the photo is uploaded" [ -n "$photo_name" ]
api POST "/scan-sessions/$session_id/photos" -H 'Content-Type: application/json' -d "{\"url\":\"$photo_url\"}" >/dev/null
photos_before="$(api GET "/scan-sessions/$session_id" | json_field photos)"
check "the photo is attached to the session (got $photos_before)" [ "$photos_before" = "1" ]

echo "== Snapshot and off-box backup =="
snapshot="$($compose exec -T scan-service frankenphp php-cli /app/tools/snapshot-db.php)"
check "snapshot-db.php writes a snapshot ($snapshot)" [ -f "$svc/data/backups/$snapshot" ]
set +e
docker run --rm --network "$network" $(rclone_env) \
    -e SCAN_SERVICE_BACKUP_REMOTE=test:vuuro-scan-backups \
    -e SCAN_SERVICE_BACKUP_DIR=/backups \
    -e SCAN_SERVICE_PHOTOS_DIR=/photos \
    -v "$svc_mount/scripts:/scripts:ro" \
    -v "$svc_mount/data/backups:/backups" \
    -v "$svc_mount/data/photos:/photos" \
    --entrypoint sh rclone/rclone:latest /scripts/backup-offbox.sh 2>"$work/backup.err"
rc=$?
set -e
check "backup-offbox.sh exits 0 (got $rc)" [ "$rc" = "0" ]
[ "$rc" = "0" ] || cat "$work/backup.err"

echo "== The server loses its data =="
$compose stop scan-service >/dev/null 2>&1
rm -rf "$svc/data"
mkdir -p "$svc/data"
$compose up -d >/dev/null 2>&1
check "the stack comes back healthy on an empty data folder" wait_healthy
check "the session is gone after the wipe (got $(status_of "/scan-sessions/$session_id"))" [ "$(status_of "/scan-sessions/$session_id")" != "200" ]

echo "== restore-offbox.sh --yes =="
set +e
SCAN_SERVICE_BACKUP_REMOTE=test:vuuro-scan-backups RCLONE_BIN="$work/bin/rclone" SCAN_SERVICE_COMPOSE="$compose" \
    sh "$svc/scripts/restore-offbox.sh" --yes >"$work/restore.out" 2>"$work/restore.err"
rc=$?
set -e
check "restore-offbox.sh exits 0 (got $rc)" [ "$rc" = "0" ]
[ "$rc" = "0" ] || { cat "$work/restore.out" "$work/restore.err"; }
check "restore-check.php passes" grep -q "restore-check: OK" "$work/restore.out"
check "restore-check.php read the photo back" grep -q "photo $photo_name of that session comes back" "$work/restore.out"

session="$(api GET "/scan-sessions/$session_id")"
check "the session reads back with its old token" [ "$(status_of "/scan-sessions/$session_id")" = "200" ]
check "both rooms are back (got $(printf '%s' "$session" | json_field rooms))" [ "$(printf '%s' "$session" | json_field rooms)" = "2" ]
check "the note is back" sh -c 'printf "%s" "$1" | grep -q "$2"' _ "$session" "$note_text"
check "the photo is attached again" [ "$(printf '%s' "$session" | json_field photos)" = "1" ]
curl -s "$base_url/scan-sessions/$session_id/photo-uploads/$photo_name" -H "X-Scan-Access-Token: $token" -o "$work_native/photo.back"
check "the photo bytes are identical" cmp -s "$work/photo.png" "$work/photo.back"

aside="$(find "$svc/data" -maxdepth 1 -type d -name 'pre-restore-*' | head -n 1)"
check "the data that was there is kept in pre-restore-*" test -f "${aside:-/nonexistent}/scan_service.sqlite"
check "no restore-* staging folder is left behind" [ -z "$(find "$svc/data" -maxdepth 1 -type d -name 'restore-*')" ]
check "the real data folder was never touched" [ "$(ls -A "$source_dir/data" 2>/dev/null)" = "$real_data_before" ]

echo
echo "$failures failure(s) out of $checks check(s)."
if [ "$failures" = "0" ]; then
    echo "TEST VERDICT: GREEN"
else
    echo "TEST VERDICT: RED"
    exit 1
fi
