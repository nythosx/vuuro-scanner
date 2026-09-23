#!/bin/sh
set -eu

export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
service_dir="$(pwd -W 2>/dev/null || pwd)"

suffix="$$"
network="vuuro-backup-test-$suffix"
minio="vuuro-minio-$suffix"
work="$(mktemp -d)"
work_mount="$(cd "$work" && (pwd -W 2>/dev/null || pwd))"
failures=0
checks=0

cleanup() {
    docker rm -f "$minio" >/dev/null 2>&1 || true
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
        -e RCLONE_CONFIG_TEST_PROVIDER=Minio \
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
        -v "$service_dir/scripts:/scripts:ro" \
        -v "$work_mount/backups:/backups" \
        --entrypoint sh rclone/rclone:latest "$@"
}

mkdir -p "$work/backups"
docker network create "$network" >/dev/null
docker run -d --name "$minio" --network "$network" \
    -e MINIO_ROOT_USER=vuurotest -e MINIO_ROOT_PASSWORD=vuurotestsecret \
    quay.io/minio/minio:latest server /data >/dev/null

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
    rclone_run http://"$minio":9000 -c "rclone lsf --files-only test:vuuro-scan-backups/$1/"
}

run_backup() {
    set +e
    rclone_run "$1" /scripts/backup-offbox.sh 2>"$work/last.err"
    rc=$?
    set -e
}

ready=1
for _ in $(seq 1 30); do
    if rclone_run http://"$minio":9000 -c 'rclone lsd test: >/dev/null 2>&1'; then
        ready=0
        break
    fi
    sleep 1
done
check "MinIO is reachable" [ "$ready" = "0" ]
[ "$ready" = "0" ] || exit 1

echo "== Newest local backup is uploaded =="
make_backup 20260920T030000Z.sqlite old
make_backup 20260923T030000Z.sqlite newest
run_backup http://"$minio":9000
check "backup script exits 0 against a reachable remote" [ "$rc" = "0" ]
daily="$(remote_ls daily)"
check "newest backup exists in daily/" has_line "$daily" 20260923T030000Z.sqlite
check "older local backups are not uploaded" lacks_line "$daily" 20260920T030000Z.sqlite
check "exactly one weekly copy exists, named by ISO week" count_is "$(remote_ls weekly)" '^[0-9]\{4\}-W[0-9]\{2\}\.sqlite$' 1
content="$(rclone_run http://"$minio":9000 -c 'rclone cat test:vuuro-scan-backups/daily/20260923T030000Z.sqlite' | tail -c 6)"
check "uploaded object content matches the local file" [ "$content" = "newest" ]

echo "== Daily retention keeps only the configured count =="
rclone_run http://"$minio":9000 -c '
for d in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16; do
    printf "SQLite format 3\000seed" | rclone rcat "test:vuuro-scan-backups/daily/202608${d}T030000Z.sqlite"
done'
KEEP_DAILY=14
run_backup http://"$minio":9000
unset KEEP_DAILY
check "backup script exits 0 with retention pruning" [ "$rc" = "0" ]
daily="$(remote_ls daily)"
check "exactly 14 daily backups remain" count_is "$daily" '\.sqlite$' 14
check "the newest backup survives pruning" has_line "$daily" 20260923T030000Z.sqlite
check "the oldest seeded backup was pruned" lacks_line "$daily" 20260801T030000Z.sqlite
check "the 14 kept are the newest 14" has_line "$daily" 20260804T030000Z.sqlite

echo "== Weekly retention keeps only the configured count =="
rclone_run http://"$minio":9000 -c '
for w in 01 02 03 04 05 06 07 08 09 10; do
    printf "SQLite format 3\000seed" | rclone rcat "test:vuuro-scan-backups/weekly/2026-W${w}.sqlite"
done'
KEEP_WEEKLY=8
run_backup http://"$minio":9000
unset KEEP_WEEKLY
weekly="$(remote_ls weekly)"
check "exactly 8 weekly backups remain" count_is "$weekly" '\.sqlite$' 8
check "the current week survives pruning" has_line "$weekly" "$(date -u +%G-W%V).sqlite"
check "the oldest seeded week was pruned" lacks_line "$weekly" 2026-W01.sqlite

echo "== Failure paths exit non-zero =="
run_backup http://vuuro-no-such-host:9000
check "unreachable remote exits 4 (got $rc)" [ "$rc" = "4" ]
check "unreachable remote logs a clear error" grep -q "unreachable" "$work/last.err"

REMOTE=''
run_backup http://"$minio":9000
unset REMOTE
check "missing SCAN_SERVICE_BACKUP_REMOTE exits 2 (got $rc)" [ "$rc" = "2" ]
check "missing remote logs a clear error" grep -q "SCAN_SERVICE_BACKUP_REMOTE is not set" "$work/last.err"

KEEP_DAILY=abc
run_backup http://"$minio":9000
unset KEEP_DAILY
check "a non-numeric keep count exits 2 (got $rc)" [ "$rc" = "2" ]
check "a non-numeric keep count logs a clear error" grep -q "KEEP_DAILY must be a whole number" "$work/last.err"

rm -f "$work/backups"/*.sqlite
run_backup http://"$minio":9000
check "an empty backup directory exits 3 (got $rc)" [ "$rc" = "3" ]

printf 'not a database' > "$work/backups/20260924T030000Z.sqlite"
run_backup http://"$minio":9000
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
