# Hosted Scan Service — pilot spec

Status: draft, awaiting go-ahead. Nothing bought or deployed.

## Goal

Move the Scan Service off the local network so the app can be tested
from anywhere and a small pilot can run without a machine on-site.
Smallest responsible setup that covers HTTPS, off-box backups, and
photo storage — no more.

## What already exists in the repo

- `docker-compose.yml` + `Dockerfile` — FrankenPHP + SQLite + Caddy
- `docker-compose.prod.yml` + `Caddyfile` — automatic HTTPS via Let's Encrypt once a domain is set; passes every value in `.env` into the container
- `scripts/server-setup.sh` — one script that sets up a fresh Ubuntu 24.04 server (below)
- `scripts/nightly.sh` — retention, a fresh database snapshot, then the off-box copy
- `scripts/backup-offbox.sh` — rclone-based off-box copy of the database and the photos
- `scripts/restore-offbox.sh` — puts the database and photos back from the off-box copy
- `scripts/tls-local-up.sh` — local self-signed HTTPS for testing
- Token hashing at rest, idempotency keys, rate limiting — all shipped

This is a deployment, not a feature.

## Provider options

| Provider | Size | Monthly | Notes |
| --- | --- | --- | --- |
| Hetzner Cloud | CX22 (2 vCPU, 4 GB, 40 GB SSD) | ~€4.50 | Cheapest, EU-based, good for Dutch pilot |
| DigitalOcean | Basic Droplet (1 vCPU, 1 GB, 25 GB SSD) | ~$6 | Most familiar, wider docs |
| Vultr | Cloud Compute (1 vCPU, 1 GB, 25 GB SSD) | ~$6 | Similar to DO |
| Fly.io | Shared-cpu-1x, 256 MB | ~$2-4 | Serverless, but SQLite volume needs care |

Recommendation: **Hetzner CX22**. Cheapest that comfortably runs
FrankenPHP + Caddy + SQLite + off-box backup script. 4 GB RAM leaves
headroom for concurrent photo uploads and PDF rendering.

## Setup steps (about 30 minutes)

1. Create the server: Hetzner CX22, Ubuntu 24.04, with an SSH key.
2. Log in as root and run:
   - `apt-get update && apt-get install -y git`
   - `git clone --branch feature/vuuro-scan https://github.com/nythosx/vuuro-scanner.git /opt/vuuro-scan`
   - `sh /opt/vuuro-scan/scan-service/scripts/server-setup.sh --domain scan.vuuro.nl --backup-remote r2:vuuro-scan-backups`
3. What the script does (safe to run again; a second run never changes the secrets):
   - installs Docker (official apt repository), rclone, ufw and fail2ban
   - firewall: only 22, 80 and 443 open
   - creates the deploy user `vuuro` (in the docker group, with root's SSH keys) and gives it `/opt/vuuro-scan`
   - SSH: only when root or `vuuro` has an SSH key, writes `/etc/ssh/sshd_config.d/10-vuuro.conf` (password login off, root by key only). It is read before Hetzner's `50-cloud-init.conf`, so it wins. It checks the config with `sshd -t` and `sshd -T` before reloading; if either fails it removes the file and stops. Without a key it only prints a warning and leaves password login on, so it cannot lock you out
   - fail2ban: the Ubuntu package already bans repeated failed SSH logins (`sshd` jail on by default), the script only enables the service
   - creates `scan-service/.env` from `.env.example` only if it does not exist yet: new random `SCAN_SERVICE_ADMIN_API_KEY`, `SCAN_SERVICE_EXPORT_SECRET` and `SCAN_SERVICE_APP_KEY` (`openssl rand -hex 32`), the domain, and `https://<domain>` as public URL, `chmod 600`. It prints where the file is, never the secrets
   - `docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build`
   - cron `/etc/cron.d/vuuro-scan`: every night at 03:00 UTC `scripts/nightly.sh` (retention via `POST /admin/run-retention`, a fresh database snapshot, then the off-box copy), log in `/var/log/vuuro-scan-nightly.log`, rotated weekly
   - prints the exact DNS records to add, then checks `https://<domain>/health` for up to 5 minutes and says either "HTTPS is up" or "STILL WAITING FOR DNS"
4. Add the DNS records it printed (A, and AAAA if it printed one) for `scan.vuuro.nl`. When they are live, run the same command again: it ends with "HTTPS is up" and checks that starting a scan without the app key gets 401.
5. Off-box backup:
   - Create a Cloudflare R2 bucket (10 GB free) or Backblaze B2 (10 GB free), see `scan-service/README.md`
   - As root: `rclone config`, with the remote name used in `--backup-remote` (e.g. `r2`)
   - Test once by hand: `sh /opt/vuuro-scan/scan-service/scripts/nightly.sh`, then check the bucket has `daily/`, `weekly/` and `photos/`
6. Alerts:
   - Backup did not run: create a free check on healthchecks.io (period 1 day, grace 2 hours, email alert), put its ping URL in `SCAN_SERVICE_HEALTHCHECK_URL` in `scan-service/.env`. `nightly.sh` pings it at the start, on success and on failure; a failing ping never stops the backup. The URL is never logged; keep it out of chat and tickets
   - Service is down: a free uptime monitor (e.g. UptimeRobot) on `https://scan.vuuro.nl/health`, every 5 minutes, alert by email
7. Point the iOS app at `https://scan.vuuro.nl`:
   - Change `SCAN_SERVICE_BASE_URL` in `ios-app/project.yml`
   - The Release/TestFlight build needs the same app key as the server. Read it on the server with `grep '^SCAN_SERVICE_APP_KEY=' /opt/vuuro-scan/scan-service/.env` and pass it as the build setting `SCAN_SERVICE_APP_KEY` at archive time (from a CI secret, never committed). The app sends it as `X-Scan-App-Key` when it starts a scan
   - Do not upload a build that contains the key as a workflow artifact on the public GitHub mirror; anyone can download those
   - Rebuild and distribute
   - The key ships inside the app and can be extracted. With the per-IP rate limit it stops casual abuse of a public URL; it is not user authentication
8. TestFlight build (`.github/workflows/ios-testflight.yml`, started by hand from the Actions tab, never on push). Not run yet: it needs App Store Connect access from Mark. Add these repository secrets on the GitHub mirror first; the workflow stops at its first step and names any that are missing:
   - `IOS_CERTIFICATE_P12_BASE64`, `IOS_CERTIFICATE_PASSWORD`: the Apple Distribution certificate (.p12, base64) and its password
   - `IOS_APPSTORE_PROFILE_BASE64`: an App Store distribution provisioning profile for `com.vuuro.scan` (base64); an ad-hoc profile is refused
   - `IOS_DEVELOPMENT_TEAM`: the Apple team ID
   - `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64`: an App Store Connect API key (App Manager role) and its .p8 file (base64)
   - `SCAN_SERVICE_APP_KEY`: the same value as on the server
   - The build points at `https://scan.vuuro.nl`. The build number is the workflow run number unless one is typed in. The workflow uploads straight to TestFlight and never keeps the .ipa or archive as a workflow artifact, because the mirror is public and the build contains the app key

Notes:

- Every value in `.env` reaches the container, including the retention days. `.env.example` leaves them empty, so automatic deletion is off on a new server and the nightly retention call deletes nothing. Switch it on per purpose under Settings on the admin page (suggested: check-out 30 days, listing 90, other 180, check-in and renovation 365) once Mark has decided the days.
- Docker publishes ports past ufw. Only 80 and 443 are published in production (8089 is not), so this is fine as long as no other port is added to the compose files.
- Updating later: as `vuuro`, `git -C /opt/vuuro-scan pull --ff-only`, then as root run `server-setup.sh` again (it rebuilds and restarts the stack).

## Restore from the off-box copy

Use this when the server or its disk is lost, or the data on it is broken. On a new server, run the setup steps first, then restore before the first 03:00 run. If the nightly job runs first, it stops with exit 5 instead of emptying the remote photos; its fresh empty database copy only lands in `daily/` next to the older copies.

1. As root: `cd /opt/vuuro-scan/scan-service`
2. `sh scripts/restore-offbox.sh --yes` for the newest database copy, or `sh scripts/restore-offbox.sh --yes --db 20261006T030000Z.sqlite` for a specific one (list them with `rclone lsf r2:vuuro-scan-backups/daily/`)
3. The script:
   - downloads the database copy and all photos into `data/restore-<time>/`
   - stops the scan service
   - moves the current `data/scan_service.sqlite` (with its `-wal`/`-shm` files) and `data/photos/` to `data/pre-restore-<time>/`; nothing is deleted
   - puts the downloaded files in place and starts the stack
   - waits for `/health`, then runs `tools/restore-check.php`: database integrity check, session and photo counts, and the newest session that has a photo, plus that photo, read back through the API with the admin key
4. Open the admin page and one session to check by eye. When it looks right, delete `data/pre-restore-<time>/`.

The photos on the remote are a mirror of the current set, not one copy per day. An older database copy can therefore miss photos that were deleted since, and photos of sessions created after that copy have no session in the database (the check reports them as photo folders without a session).

## Cost summary

| Item | Monthly |
| --- | --- |
| VPS (Hetzner CX22) | ~€4.50 |
| Domain (or DuckDNS) | €0 (DuckDNS) / ~€10/year (real domain) |
| Off-box backup (R2 or B2, 10 GB free) | €0 |
| TLS (Let's Encrypt via Caddy) | €0 |
| **Total** | **~€5/month** |

## What this does NOT include

- Multiple app replicas or load balancing (SQLite is single-writer)
- Real user accounts or per-org isolation
- Server-side legal agreement proof (see ADR 0006)
- CDN or edge rate limiting

## Preconditions before this is "pilot safe"

- [x] HTTPS available (Caddy + Let's Encrypt)
- [x] Token hashing at rest
- [x] Off-box backup of the database and the photos (tested locally against an S3 test server)
- [x] Restore script, tested locally with `scripts/test-restore.sh` (throwaway stack: session with rooms, note and photo, snapshot, off-box backup, wipe `data/`, `restore-offbox.sh --yes`, session, note and photo read back). Set `RESTORE_TEST_BASE_IMAGE` to an already-built image when Docker Hub is too slow to pull the base image
- [x] Server setup script (syntax-checked and dry-run in an Ubuntu 24.04 container; not yet run on a real Hetzner server)
- [ ] Real domain or DuckDNS subdomain chosen
- [ ] `.env` with real secrets set (not defaults), including `SCAN_SERVICE_APP_KEY`
- [ ] Off-box backup verified once by hand on the server (`scripts/nightly.sh`)
- [ ] Restore tried once on the real server
- [ ] Retention policy decided per purpose and switched on under Settings on the admin page (off by default; nothing is deleted until then)

## Decision needed

Mark: send the Hetzner invite and add the DNS records the setup script prints for `scan.vuuro.nl`. Also confirm the retention days per purpose, and R2 or B2 for the off-box copy.
