#!/bin/sh
set -eu

export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
service_dir="$(pwd -W 2>/dev/null || pwd)"

suffix="$$"
network="vuuro-backup-test-$suffix"
s3server="vuuro-s3-$suffix"
work="$(mktemp -d)"
work_mount="$(cd "$work" && (pwd -W 2>/dev/null || pwd))"
failures=0
checks=0

cleanup() {
    docker rm -f "$s3server" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT INT TERM

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

make_backup() {
    printf 'SQLite format 3\000%s' "$2" > "$work/backups/$1"
}

rclone_run() {
    endpoint="$1"
    shift
    docker run --rm --network "$network" \
        -e RCLONE_CONFIG_TEST_TYPE=s3 \
        -e RCLONE_CONFIG_TEST_PROVIDER=Rclone \
        -e RCLONE_CONFIG_TEST_ACCESS_KEY_ID=vuurotest \
        -e RCLONE_CONFIG_TEST_SECRET_ACCESS_KEY=vuurotestsecret \
        -e RCLONE_CONFIG_TEST_ENDPOINT="$endpoint" \
        -e RCLONE_CONFIG_TEST_LOW_LEVEL_RETRIES=1 \
        -e RCLONE_RETRIES=1 \
        -e RCLONE_CONTIMEOUT=3s \
        -e RCLONE_CONFIG=/dev/null \
        -e SCAN_SERVICE_BACKUP_DIR=/backups \
        -e SCAN_SERVICE_BACKUP_REMOTE="${REMOTE-test:vuuro-scan-backups}" \
        -e SCAN_SERVICE_BACKUP_KEEP_DAILY="${KEEP_DAILY:-14}" \
        -e SCAN_SERVICE_BACKUP_KEEP_WEEKLY="${KEEP_WEEKLY:-8}" \
        -e SCAN_SERVICE_BACKUP_ALLOW_EMPTY_PHOTOS="${ALLOW_EMPTY_PHOTOS:-}" \
        -e SCAN_SERVICE_PHOTOS_DIR=/photos \
        -v "$service_dir/scripts:/scripts:ro" \
        -v "$work_mount/backups:/backups" \
        -v "$work_mount/photos:/photos" \
        --entrypoint sh rclone/rclone:latest "$@"
}

mkdir -p "$work/backups" "$work/photos"
docker network create "$network" >/dev/null
docker run -d --name "$s3server" --network "$network" \
    rclone/rclone:latest serve s3 --addr :9000 --auth-key vuurotest,vuurotestsecret /data >/dev/null

has_line() {
    printf '%s\n' "$1" | grep -qx "$2"
}

lacks_line() {
    ! has_line "$1" "$2"
}

count_is() {
    [ "$(printf '%s\n' "$1" | grep -c "$2" || true)" = "$3" ]
}

remote_ls() {
    rclone_run http://"$s3server":9000 -c "rclone lsf --files-only test:vuuro-scan-backups/$1/"
}

remote_photos() {
    rclone_run http://"$s3server":9000 -c "rclone lsf -R --files-only test:vuuro-scan-backups/photos/"
}

run_backup() {
    set +e
    rclone_run "$1" /scripts/backup-offbox.sh 2>"$work/last.err"
    rc=$?
    set -e
}

ready=1
for _ in $(seq 1 30); do
    if rclone_run http://"$s3server":9000 -c 'rclone lsd test: >/dev/null 2>&1'; then
        ready=0
        break
    fi
    sleep 1
done
check "the S3 test server is reachable" [ "$ready" = "0" ]
[ "$ready" = "0" ] || exit 1

echo "== Newest local backup is uploaded =="
make_backup 20260920T030000Z.sqlite old
make_backup 20260923T030000Z.sqlite newest
run_backup http://"$s3server":9000
check "backup script exits 0 against a reachable remote" [ "$rc" = "0" ]
daily="$(remote_ls daily)"
check "newest backup exists in daily/" has_line "$daily" 20260923T030000Z.sqlite
check "older local backups are not uploaded" lacks_line "$daily" 20260920T030000Z.sqlite
check "exactly one weekly copy exists, named by ISO week" count_is "$(remote_ls weekly)" '^[0-9]\{4\}-W[0-9]\{2\}\.sqlite$' 1
content="$(rclone_run http://"$s3server":9000 -c 'rclone cat test:vuuro-scan-backups/daily/20260923T030000Z.sqlite' | tail -c 6)"
check "uploaded object content matches the local file" [ "$content" = "newest" ]

echo "== Daily retention keeps only the configured count =="
rclone_run http://"$s3server":9000 -c '
for d in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16; do
    printf "SQLite format 3\000seed" | rclone rcat "test:vuuro-scan-backups/daily/202608${d}T030000Z.sqlite"
done'
KEEP_DAILY=14
run_backup http://"$s3server":9000
unset KEEP_DAILY
check "backup script exits 0 with retention pruning" [ "$rc" = "0" ]
daily="$(remote_ls daily)"
check "exactly 14 daily backups remain" count_is "$daily" '\.sqlite$' 14
check "the newest backup survives pruning" has_line "$daily" 20260923T030000Z.sqlite
check "the oldest seeded backup was pruned" lacks_line "$daily" 20260801T030000Z.sqlite
check "the 14 kept are the newest 14" has_line "$daily" 20260804T030000Z.sqlite

echo "== Weekly retention keeps only the configured count =="
rclone_run http://"$s3server":9000 -c '
for w in 01 02 03 04 05 06 07 08 09 10; do
    printf "SQLite format 3\000seed" | rclone rcat "test:vuuro-scan-backups/weekly/2026-W${w}.sqlite"
done'
KEEP_WEEKLY=8
run_backup http://"$s3server":9000
unset KEEP_WEEKLY
weekly="$(remote_ls weekly)"
check "exactly 8 weekly backups remain" count_is "$weekly" '\.sqlite$' 8
check "the current week survives pruning" has_line "$weekly" "$(date -u +%G-W%V).sqlite"
check "the oldest seeded week was pruned" lacks_line "$weekly" 2026-W01.sqlite

echo "== Photos are copied off-box =="
mkdir -p "$work/photos/session-a" "$work/photos/session-b"
printf 'photo-a1' > "$work/photos/session-a/a1.jpg"
printf 'photo-a2' > "$work/photos/session-a/a2.png"
printf 'photo-b1' > "$work/photos/session-b/b1.jpg"
run_backup http://"$s3server":9000
check "backup script exits 0 with photos (got $rc)" [ "$rc" = "0" ]
photos="$(remote_photos)"
check "every photo is on the remote" count_is "$photos" '\.' 3
check "photos keep their session folder" has_line "$photos" session-b/b1.jpg
photo_content="$(rclone_run http://"$s3server":9000 -c 'rclone cat test:vuuro-scan-backups/photos/session-a/a2.png')"
check "photo content matches the local file" [ "$photo_content" = "photo-a2" ]
check "database copies are not touched by the photo copy" count_is "$(remote_ls daily)" '\.sqlite$' 14

echo "== A deleted session's photos are deleted off-box too =="
rm -rf "$work/photos/session-b"
run_backup http://"$s3server":9000
photos="$(remote_photos)"
check "backup script exits 0 after a session is deleted (got $rc)" [ "$rc" = "0" ]
check "the deleted session's photo is gone from the remote" lacks_line "$photos" session-b/b1.jpg
check "the other session's photos stay" has_line "$photos" session-a/a1.jpg

echo "== An empty photo folder never empties the remote =="
mv "$work/photos/session-a" "$work/session-a.kept"
run_backup http://"$s3server":9000
check "an empty photo folder with photos on the remote exits 5 (got $rc)" [ "$rc" = "5" ]
check "it logs why it refused" grep -q "refusing to empty the remote copy" "$work/last.err"
check "the remote photos are untouched" count_is "$(remote_photos)" '\.' 2
ALLOW_EMPTY_PHOTOS=1
run_backup http://"$s3server":9000
unset ALLOW_EMPTY_PHOTOS
check "SCAN_SERVICE_BACKUP_ALLOW_EMPTY_PHOTOS=1 lets it through (got $rc)" [ "$rc" = "0" ]
check "and then the remote photos are emptied" [ -z "$(remote_photos)" ]
mv "$work/session-a.kept" "$work/photos/session-a"
run_backup http://"$s3server":9000
check "photos come back on the next run" count_is "$(remote_photos)" '\.' 2

echo "== Failure paths exit non-zero =="
run_backup http://vuuro-no-such-host:9000
check "unreachable remote exits 4 (got $rc)" [ "$rc" = "4" ]
check "unreachable remote logs a clear error" grep -q "unreachable" "$work/last.err"

REMOTE=''
run_backup http://"$s3server":9000
unset REMOTE
check "missing SCAN_SERVICE_BACKUP_REMOTE exits 2 (got $rc)" [ "$rc" = "2" ]
check "missing remote logs a clear error" grep -q "SCAN_SERVICE_BACKUP_REMOTE is not set" "$work/last.err"

KEEP_DAILY=abc
run_backup http://"$s3server":9000
unset KEEP_DAILY
check "a non-numeric keep count exits 2 (got $rc)" [ "$rc" = "2" ]
check "a non-numeric keep count logs a clear error" grep -q "KEEP_DAILY must be a whole number" "$work/last.err"

rm -f "$work/backups"/*.sqlite
run_backup http://"$s3server":9000
check "an empty backup directory exits 3 (got $rc)" [ "$rc" = "3" ]

printf 'not a database' > "$work/backups/20260924T030000Z.sqlite"
run_backup http://"$s3server":9000
check "a non-SQLite newest backup exits 3 (got $rc)" [ "$rc" = "3" ]
check "a non-SQLite backup logs a clear error" grep -q "is not a SQLite database" "$work/last.err"
check "a non-SQLite backup is never uploaded" lacks_line "$(remote_ls daily)" 20260924T030000Z.sqlite

echo
echo "$failures failure(s) out of $checks check(s)."
if [ "$failures" = "0" ]; then
    echo "TEST VERDICT: GREEN"
else
    echo "TEST VERDICT: RED"
    exit 1
fi
