#!/bin/sh
set -u

log() {
    printf '%s nightly: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
service_dir="$(cd "$script_dir/.." && pwd)"
env_file="${SCAN_SERVICE_ENV_FILE:-$service_dir/.env}"
compose="docker compose -f docker-compose.yml -f docker-compose.prod.yml"
status=0

env_value() {
    sed -n "s/^$1=//p" "$env_file" | tail -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

[ -f "$env_file" ] || { log "ERROR: $env_file not found"; exit 2; }

healthcheck_url="$(env_value SCAN_SERVICE_HEALTHCHECK_URL)"
healthcheck_url="${healthcheck_url%/}"

ping_healthcheck() {
    [ -n "$healthcheck_url" ] || return 0
    curl -fsS -m 10 --retry 3 -o /dev/null "$healthcheck_url$1" >/dev/null 2>&1 || log "WARNING: healthcheck ping failed, the backup itself is not affected"
}

finish() {
    if [ "$1" -eq 0 ]; then
        ping_healthcheck ""
    else
        ping_healthcheck "/fail"
    fi
    exit "$1"
}

ping_healthcheck "/start"
cd "$service_dir" || finish 2

domain="$(env_value SCAN_SERVICE_DOMAIN)"
admin_key="$(env_value SCAN_SERVICE_ADMIN_API_KEY)"

if [ -z "$domain" ] || [ -z "$admin_key" ]; then
    log "ERROR: SCAN_SERVICE_DOMAIN or SCAN_SERVICE_ADMIN_API_KEY is empty in $env_file, retention skipped"
    status=2
else
    round=1
    while [ "$round" -le 5 ]; do
        response="$(printf 'X-Admin-Api-Key: %s\n' "$admin_key" | curl -fsS --max-time 60 --resolve "$domain:443:127.0.0.1" -H @- -X POST "https://$domain/admin/run-retention" 2>&1)" || {
            log "ERROR: retention call failed: $response"
            status=4
            break
        }
        purged="$(printf '%s' "$response" | sed -n 's/.*"purged": *\([0-9]*\).*/\1/p')"
        log "retention: purged ${purged:-?} session(s)"
        [ "${purged:-0}" -ge 100 ] || break
        round=$((round + 1))
    done
fi

if snapshot="$($compose exec -T scan-service frankenphp php-cli /app/tools/snapshot-db.php)"; then
    log "database snapshot $snapshot written"
else
    log "ERROR: database snapshot failed, the off-box copy would be stale"
    finish 3
fi

remote="$(env_value SCAN_SERVICE_BACKUP_REMOTE)"
if [ -z "$remote" ]; then
    log "ERROR: SCAN_SERVICE_BACKUP_REMOTE is empty in $env_file, nothing was copied off the server"
    finish 2
fi
SCAN_SERVICE_BACKUP_REMOTE="$remote"
export SCAN_SERVICE_BACKUP_REMOTE
keep_daily="$(env_value SCAN_SERVICE_BACKUP_KEEP_DAILY)"
if [ -n "$keep_daily" ]; then
    SCAN_SERVICE_BACKUP_KEEP_DAILY="$keep_daily"
    export SCAN_SERVICE_BACKUP_KEEP_DAILY
fi
keep_weekly="$(env_value SCAN_SERVICE_BACKUP_KEEP_WEEKLY)"
if [ -n "$keep_weekly" ]; then
    SCAN_SERVICE_BACKUP_KEEP_WEEKLY="$keep_weekly"
    export SCAN_SERVICE_BACKUP_KEEP_WEEKLY
fi

sh "$script_dir/backup-offbox.sh" || { rc=$?; log "ERROR: off-box backup failed with exit $rc"; finish "$rc"; }

[ "$status" -eq 0 ] || log "finished with errors (exit $status)"
finish "$status"
