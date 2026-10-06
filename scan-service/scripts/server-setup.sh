#!/bin/sh
set -eu

say() {
    printf '\n== %s\n' "$*"
}

fail() {
    printf 'server-setup: ERROR: %s\n' "$1" >&2
    exit "${2:-1}"
}

usage() {
    cat >&2 <<'EOF'
Usage: server-setup.sh --domain <host> [options]

  --domain <host>          public host name, e.g. scan.vuuro.nl (required)
  --repo <url>             git URL to clone when --dir is not a clone yet
  --branch <name>          branch to check out (default: keep the current one)
  --dir <path>             where the repo lives (default /opt/vuuro-scan)
  --user <name>            non-root deploy user (default vuuro)
  --backup-remote <remote> rclone remote for off-box backups, e.g. r2:vuuro-scan-backups
  --wait <seconds>         how long to wait for HTTPS at the end (default 300)

Run as root on a fresh Ubuntu 24.04 server. Safe to run again.
EOF
    exit 2
}

domain="${SCAN_SERVICE_DOMAIN:-}"
repo_url="${SCAN_SERVICE_REPO_URL:-}"
branch="${SCAN_SERVICE_REPO_BRANCH:-}"
install_dir="${SCAN_SERVICE_INSTALL_DIR:-/opt/vuuro-scan}"
deploy_user="${SCAN_SERVICE_DEPLOY_USER:-vuuro}"
backup_remote="${SCAN_SERVICE_BACKUP_REMOTE:-}"
wait_seconds=300

while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage
    case "$1" in
        --domain) domain="$2" ;;
        --repo) repo_url="$2" ;;
        --branch) branch="$2" ;;
        --dir) install_dir="$2" ;;
        --user) deploy_user="$2" ;;
        --backup-remote) backup_remote="$2" ;;
        --wait) wait_seconds="$2" ;;
        *) usage ;;
    esac
    shift 2
done

[ "$(id -u)" = "0" ] || fail "run this as root (sudo sh $0 ...)" 2
case "$domain" in
    ''|.*|*.|*[!A-Za-z0-9.-]*|*..*) fail "--domain must be a plain host name like scan.vuuro.nl, got '$domain'" 2 ;;
esac
case "$install_dir" in
    /*) ;;
    *) fail "--dir must be an absolute path, got '$install_dir'" 2 ;;
esac
case "$install_dir" in
    *[!A-Za-z0-9/._-]*) fail "--dir may only use letters, digits, / . _ -, got '$install_dir'" 2 ;;
esac
case "$deploy_user" in
    ''|*[!a-z0-9_-]*) fail "--user must be a lowercase user name, got '$deploy_user'" 2 ;;
esac
case "$wait_seconds" in
    ''|*[!0-9]*) fail "--wait must be a whole number of seconds, got '$wait_seconds'" 2 ;;
esac
case "$backup_remote" in
    ''|*:*) ;;
    *) fail "--backup-remote must look like name:bucket, got '$backup_remote'" 2 ;;
esac

if [ -r /etc/os-release ]; then
    os_id="$(. /etc/os-release && echo "${ID:-}")"
    os_version="$(. /etc/os-release && echo "${VERSION_ID:-}")"
else
    os_id=""
    os_version=""
fi
[ "$os_id" = "ubuntu" ] || fail "this script is written for Ubuntu, found '${os_id:-unknown}'" 2
[ "$os_version" = "24.04" ] || printf 'server-setup: warning: tested for Ubuntu 24.04, this is %s\n' "$os_version" >&2

export DEBIAN_FRONTEND=noninteractive

say "Packages"
apt-get update -q
apt-get install -y -q ca-certificates curl git ufw rclone openssl cron

if docker compose version >/dev/null 2>&1; then
    echo "Docker with the compose plugin is already installed"
else
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -q
    apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker >/dev/null 2>&1 || true
systemctl enable --now cron >/dev/null 2>&1 || true

say "Firewall (22, 80, 443 only)"
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null
ufw status | sed -n '1,20p'

say "Deploy user $deploy_user"
if id -u "$deploy_user" >/dev/null 2>&1; then
    echo "user $deploy_user already exists"
else
    useradd --create-home --shell /bin/bash "$deploy_user"
    echo "created user $deploy_user"
fi
usermod -aG docker "$deploy_user"
deploy_home="$(getent passwd "$deploy_user" | cut -d: -f6)"
if [ -s /root/.ssh/authorized_keys ] && [ ! -s "$deploy_home/.ssh/authorized_keys" ]; then
    install -d -m 0700 -o "$deploy_user" -g "$deploy_user" "$deploy_home/.ssh"
    install -m 0600 -o "$deploy_user" -g "$deploy_user" /root/.ssh/authorized_keys "$deploy_home/.ssh/authorized_keys"
    echo "copied root's SSH keys to $deploy_user"
fi

say "Code in $install_dir"
as_deploy() {
    runuser -u "$deploy_user" -- "$@"
}
if [ -d "$install_dir/.git" ]; then
    [ "$(stat -c %U "$install_dir/.git")" = "$deploy_user" ] || chown -R "$deploy_user:$deploy_user" "$install_dir"
    as_deploy git -C "$install_dir" fetch --prune origin
    if [ -n "$branch" ]; then
        as_deploy git -C "$install_dir" checkout "$branch"
    fi
    as_deploy git -C "$install_dir" pull --ff-only
else
    [ -n "$repo_url" ] || fail "$install_dir is not a git clone yet; pass --repo <url> (and --branch)" 2
    if [ -e "$install_dir" ] && [ -n "$(ls -A "$install_dir" 2>/dev/null)" ]; then
        fail "$install_dir exists, is not empty and is not a git clone" 2
    fi
    install -d -o "$deploy_user" -g "$deploy_user" "$install_dir"
    if [ -n "$branch" ]; then
        as_deploy git clone --branch "$branch" "$repo_url" "$install_dir"
    else
        as_deploy git clone "$repo_url" "$install_dir"
    fi
fi
echo "at commit $(as_deploy git -C "$install_dir" rev-parse --short HEAD) on $(as_deploy git -C "$install_dir" rev-parse --abbrev-ref HEAD)"

service_dir="$install_dir/scan-service"
env_file="$service_dir/.env"
[ -f "$service_dir/docker-compose.prod.yml" ] || fail "$service_dir/docker-compose.prod.yml not found; is this the right repo and branch?" 2

env_value() {
    sed -n "s/^$1=//p" "$env_file" | tail -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

set_env_value() {
    if grep -q "^$1=" "$env_file"; then
        sed -i "s|^$1=.*|$1=$2|" "$env_file"
    else
        printf '%s=%s\n' "$1" "$2" >> "$env_file"
    fi
}

say "Settings file $env_file"
if [ -f "$env_file" ]; then
    echo "kept the existing $env_file (secrets are not changed on a re-run)"
    existing_domain="$(env_value SCAN_SERVICE_DOMAIN)"
    [ "$existing_domain" = "$domain" ] || fail "$env_file has SCAN_SERVICE_DOMAIN='$existing_domain', not '$domain'; fix one of them" 2
else
    umask 077
    cp "$service_dir/.env.example" "$env_file"
    set_env_value SCAN_SERVICE_ENV production
    set_env_value SCAN_SERVICE_ADMIN_API_KEY "$(openssl rand -hex 32)"
    set_env_value SCAN_SERVICE_EXPORT_SECRET "$(openssl rand -hex 32)"
    set_env_value SCAN_SERVICE_APP_KEY "$(openssl rand -hex 32)"
    set_env_value SCAN_SERVICE_DOMAIN "$domain"
    set_env_value SCAN_SERVICE_PUBLIC_BASE_URL "https://$domain"
    umask 022
    echo "created $env_file with new random secrets"
fi
if [ -n "$backup_remote" ] && [ -z "$(env_value SCAN_SERVICE_BACKUP_REMOTE)" ]; then
    set_env_value SCAN_SERVICE_BACKUP_REMOTE "$backup_remote"
    echo "set SCAN_SERVICE_BACKUP_REMOTE=$backup_remote"
fi
for required in SCAN_SERVICE_ADMIN_API_KEY SCAN_SERVICE_EXPORT_SECRET SCAN_SERVICE_APP_KEY; do
    [ -n "$(env_value "$required")" ] || fail "$required is empty in $env_file" 2
done
chown "$deploy_user:$deploy_user" "$env_file"
chmod 600 "$env_file"

say "Starting the stack"
cd "$service_dir"
compose="docker compose -f docker-compose.yml -f docker-compose.prod.yml"
$compose up -d --build

say "Nightly jobs"
cat > /etc/cron.d/vuuro-scan <<EOF
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * * root sh $service_dir/scripts/nightly.sh >> /var/log/vuuro-scan-nightly.log 2>&1
EOF
chmod 644 /etc/cron.d/vuuro-scan
cat > /etc/logrotate.d/vuuro-scan <<'EOF'
/var/log/vuuro-scan-nightly.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF
echo "03:00 UTC: retention, a fresh database snapshot, then the off-box copy (log: /var/log/vuuro-scan-nightly.log)"

remote="$(env_value SCAN_SERVICE_BACKUP_REMOTE)"
if [ -z "$remote" ]; then
    echo "WARNING: no off-box backup yet. Run 'rclone config' as root, then set SCAN_SERVICE_BACKUP_REMOTE in $env_file"
elif ! rclone listremotes 2>/dev/null | grep -qx "${remote%%:*}:"; then
    echo "WARNING: rclone has no remote called '${remote%%:*}'. Run 'rclone config' as root and create it, then test with: sh $service_dir/scripts/nightly.sh"
else
    echo "off-box backups go to $remote"
fi

say "Waiting for the scan service"
container="$($compose ps -q scan-service)"
health=""
tries=0
while [ "$tries" -lt 60 ]; do
    health="$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || true)"
    [ "$health" = "healthy" ] && break
    tries=$((tries + 1))
    sleep 2
done
[ "$health" = "healthy" ] || fail "the scan service container is not healthy (state: ${health:-unknown}); see: cd $service_dir && $compose logs scan-service" 3
echo "the scan service is running"

ipv4="$(ip -o -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')"
ipv6="$(ip -o -6 route get 2606:4700:4700::1111 2>/dev/null | sed -n 's/.* src \([0-9a-fA-F:]*\).*/\1/p')"

say "DNS records to add for $domain"
if [ -n "$ipv4" ]; then
    echo "  $domain.  300  IN  A     $ipv4"
else
    echo "  (no public IPv4 found on this server)"
fi
if [ -n "$ipv6" ]; then
    echo "  $domain.  300  IN  AAAA  $ipv6"
fi

say "Checking HTTPS"
deadline=$(( $(date +%s) + wait_seconds ))
https_up=0
resolved=""
while :; do
    resolved="$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
    if curl -fsS --max-time 10 -o /dev/null "https://$domain/health" 2>/dev/null; then
        https_up=1
        break
    fi
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 10
done

if [ "$https_up" = "1" ]; then
    echo "HTTPS is up: https://$domain/health answers"
    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "https://$domain/scan-sessions" || true)"
    if [ "$code" = "401" ]; then
        echo "starting a scan without the app key is refused (401), as it should be"
    else
        echo "WARNING: POST /scan-sessions without the app key returned $code, expected 401"
    fi
else
    case " $resolved" in
        *" $ipv4 "*) echo "DNS points here ($resolved) but HTTPS is not up yet. Caddy may still be getting the certificate: cd $service_dir && $compose logs caddy" ;;
        " ") echo "STILL WAITING FOR DNS: $domain does not resolve yet. Add the records above, then run this script again" ;;
        *) echo "STILL WAITING FOR DNS: $domain resolves to $resolved, not to this server ($ipv4). Fix the records above, then run this script again" ;;
    esac
fi

say "Done"
echo "Settings and secrets: $env_file (root and $deploy_user only)"
echo "The iOS Release/TestFlight build needs the same app key as its SCAN_SERVICE_APP_KEY build setting."
echo "Read it on this server with: grep '^SCAN_SERVICE_APP_KEY=' $env_file"
echo "Admin page: https://$domain/admin (key: grep '^SCAN_SERVICE_ADMIN_API_KEY=' $env_file)"
[ "$https_up" = "1" ] || exit 4
