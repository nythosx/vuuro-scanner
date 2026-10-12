#!/bin/sh
set -eu

log() {
    printf '%s backup-offbox: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

fail() {
    log "ERROR: $1"
    exit "${2:-1}"
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
backup_dir="${SCAN_SERVICE_BACKUP_DIR:-$script_dir/../data/backups}"
photos_dir="${SCAN_SERVICE_PHOTOS_DIR:-$script_dir/../data/photos}"
remote="${SCAN_SERVICE_BACKUP_REMOTE:-}"
keep_daily="${SCAN_SERVICE_BACKUP_KEEP_DAILY:-14}"
keep_weekly="${SCAN_SERVICE_BACKUP_KEEP_WEEKLY:-8}"
rclone_bin="${RCLONE_BIN:-rclone}"

[ -n "$remote" ] || fail "SCAN_SERVICE_BACKUP_REMOTE is not set (example: r2:vuuro-scan-backups)" 2
case "$keep_daily" in ''|*[!0-9]*) fail "SCAN_SERVICE_BACKUP_KEEP_DAILY must be a whole number, got '$keep_daily'" 2 ;; esac
case "$keep_weekly" in ''|*[!0-9]*) fail "SCAN_SERVICE_BACKUP_KEEP_WEEKLY must be a whole number, got '$keep_weekly'" 2 ;; esac
[ "$keep_daily" -ge 1 ] || fail "SCAN_SERVICE_BACKUP_KEEP_DAILY must be at least 1" 2
[ "$keep_weekly" -ge 1 ] || fail "SCAN_SERVICE_BACKUP_KEEP_WEEKLY must be at least 1" 2
command -v "$rclone_bin" >/dev/null 2>&1 || fail "rclone not found (install it or set RCLONE_BIN)" 2
[ -d "$backup_dir" ] || fail "backup directory $backup_dir does not exist" 3

newest=""
for f in "$backup_dir"/*.sqlite; do
    [ -f "$f" ] || continue
    newest="$f"
done
[ -n "$newest" ] || fail "no *.sqlite backups found in $backup_dir" 3
[ -s "$newest" ] || fail "newest backup $newest is empty" 3
header="$(head -c 15 "$newest")"
[ "$header" = "SQLite format 3" ] || fail "newest backup $newest is not a SQLite database" 3

name="$(basename "$newest")"
week="$(date -u +%G-W%V)"

"$rclone_bin" lsf --max-depth 1 "$remote/" >/dev/null 2>&1 || "$rclone_bin" mkdir "$remote" >/dev/null 2>&1 || fail "remote $remote is unreachable or not writable" 4

remote_listing_rc=0
remote_listing="$("$rclone_bin" lsf -R --files-only "$remote/photos/" 2>/dev/null)" || remote_listing_rc=$?
case "$remote_listing_rc" in
    0) remote_photos="$(printf '%s' "$remote_listing" | grep -c . || true)" ;;
    3) remote_photos=0 ;;
    *) remote_photos=unknown ;;
esac
if [ -d "$photos_dir" ]; then
    local_photos="$(find "$photos_dir" -type f | wc -l | tr -d ' ')"
else
    local_photos=0
fi
if [ "$local_photos" -eq 0 ] && [ "$remote_photos" != "0" ] && [ "${SCAN_SERVICE_BACKUP_ALLOW_EMPTY_PHOTOS:-}" != "1" ]; then
    fail "no photos in $photos_dir but $remote_photos on $remote/photos/; refusing to empty the remote copy (restore first, or set SCAN_SERVICE_BACKUP_ALLOW_EMPTY_PHOTOS=1 if every photo really was deleted)" 5
fi

log "uploading $name to $remote/daily/"
"$rclone_bin" copyto "$newest" "$remote/daily/$name" || fail "upload of $name to $remote/daily/ failed" 4
log "uploading $name to $remote/weekly/$week.sqlite"
"$rclone_bin" copyto "$newest" "$remote/weekly/$week.sqlite" || fail "upload to $remote/weekly/$week.sqlite failed" 4

"$rclone_bin" lsf --files-only "$remote/daily/" | grep -qx "$name" || fail "$name is missing from $remote/daily/ after upload" 4

prune() {
    folder="$1"
    keep="$2"
    listing="$("$rclone_bin" lsf --files-only "$remote/$folder/")" || fail "could not list $remote/$folder/" 4
    total="$(printf '%s\n' "$listing" | grep -c '\.sqlite$' || true)"
    excess=$((total - keep))
    [ "$excess" -gt 0 ] || return 0
    printf '%s\n' "$listing" | grep '\.sqlite$' | sort | head -n "$excess" | while IFS= read -r old; do
        log "retention: deleting $remote/$folder/$old"
        "$rclone_bin" deletefile "$remote/$folder/$old" || fail "could not delete $remote/$folder/$old" 4
    done
}

prune daily "$keep_daily"
prune weekly "$keep_weekly"

if [ -d "$photos_dir" ]; then
    log "syncing $local_photos photo file(s) to $remote/photos/"
    "$rclone_bin" sync "$photos_dir" "$remote/photos" || fail "photo sync to $remote/photos/ failed" 4
else
    log "no photo folder at $photos_dir yet, nothing to sync"
fi

log "done: $name and $local_photos photo file(s) (daily keep=$keep_daily, weekly keep=$keep_weekly)"
