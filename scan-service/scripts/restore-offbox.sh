#!/bin/sh
set -eu

log() {
    printf '%s restore-offbox: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

fail() {
    log "ERROR: $1"
    exit "${2:-1}"
}

usage() {
    echo "Usage: $0 --yes [--db <name>.sqlite]" >&2
    echo "Puts the newest (or the named) database copy from daily/ and every photo from photos/ on" >&2
    echo "SCAN_SERVICE_BACKUP_REMOTE back into data/. The current data is moved aside, not deleted." >&2
    exit 2
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
service_dir="$(cd "$script_dir/.." && pwd)"
env_file="${SCAN_SERVICE_ENV_FILE:-$service_dir/.env}"
data_dir="${SCAN_SERVICE_DATA_DIR:-$service_dir/data}"
rclone_bin="${RCLONE_BIN:-rclone}"
compose="${SCAN_SERVICE_COMPOSE:-docker compose -f docker-compose.yml -f docker-compose.prod.yml}"
confirmed=0
db_name=""

while [ $# -gt 0 ]; do
    case "$1" in
        --yes) confirmed=1 ;;
        --db) [ $# -ge 2 ] || usage; db_name="$2"; shift ;;
        *) usage ;;
    esac
    shift
done
[ "$confirmed" = "1" ] || usage

env_value() {
    [ -f "$env_file" ] || return 0
    sed -n "s/^$1=//p" "$env_file" | tail -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

remote="${SCAN_SERVICE_BACKUP_REMOTE:-$(env_value SCAN_SERVICE_BACKUP_REMOTE)}"
[ -n "$remote" ] || fail "SCAN_SERVICE_BACKUP_REMOTE is not set (in the environment or $env_file)" 2
command -v "$rclone_bin" >/dev/null 2>&1 || fail "rclone not found (install it or set RCLONE_BIN)" 2
[ -d "$data_dir" ] || mkdir -p "$data_dir"
cd "$service_dir"

if [ -z "$db_name" ]; then
    db_name="$("$rclone_bin" lsf --files-only "$remote/daily/" | grep '\.sqlite$' | sort | tail -n 1)" || true
    [ -n "$db_name" ] || fail "no database copies found in $remote/daily/" 4
fi
case "$db_name" in
    */*|'') fail "--db takes a file name from $remote/daily/, got '$db_name'" 2 ;;
    *.sqlite) ;;
    *) fail "--db must name a .sqlite file, got '$db_name'" 2 ;;
esac

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
staging="$data_dir/restore-$stamp"
aside="$data_dir/pre-restore-$stamp"
mkdir -p "$staging/photos"

log "downloading $remote/daily/$db_name"
"$rclone_bin" copyto "$remote/daily/$db_name" "$staging/scan_service.sqlite" || fail "download of $db_name failed" 4
[ "$(head -c 15 "$staging/scan_service.sqlite")" = "SQLite format 3" ] || fail "$db_name is not a SQLite database" 3
log "downloading photos from $remote/photos/"
photo_rc=0
"$rclone_bin" copy "$remote/photos" "$staging/photos" || photo_rc=$?
case "$photo_rc" in
    0) ;;
    3) log "there are no photos on the remote" ;;
    *) fail "download of the photos failed (rclone exit $photo_rc)" 4 ;;
esac
photo_count="$(find "$staging/photos" -type f | wc -l | tr -d ' ')"
log "downloaded $db_name and $photo_count photo file(s)"

log "stopping the scan service"
$compose stop scan-service >/dev/null || fail "could not stop the scan service" 5

mkdir -p "$aside"
for f in scan_service.sqlite scan_service.sqlite-wal scan_service.sqlite-shm photos; do
    if [ -e "$data_dir/$f" ]; then
        mv "$data_dir/$f" "$aside/$f"
    fi
done
mv "$staging/scan_service.sqlite" "$data_dir/scan_service.sqlite"
mv "$staging/photos" "$data_dir/photos"
rmdir "$staging"
log "the previous data is kept in $aside"

log "starting the scan service"
$compose up -d >/dev/null || fail "could not start the stack" 5

container="$($compose ps -q scan-service)"
health=""
tries=0
while [ "$tries" -lt 45 ]; do
    health="$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || true)"
    [ "$health" = "healthy" ] && break
    tries=$((tries + 1))
    sleep 2
done
[ "$health" = "healthy" ] || fail "the scan service did not become healthy (last state: ${health:-unknown}); the previous data is in $aside" 6

$compose exec -T scan-service frankenphp php-cli /app/tools/restore-check.php || fail "the restored data did not pass the check; the previous data is in $aside" 6

log "restore done from $db_name. Once you are happy, remove $aside"
