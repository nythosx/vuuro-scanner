# Hosted Scan Service — pilot spec

Status: draft, awaiting go-ahead. Nothing bought or deployed.

## Goal

Move the Scan Service off the local network so the app can be tested
from anywhere and a small pilot can run without a machine on-site.
Smallest responsible setup that covers HTTPS, off-box backups, and
photo storage — no more.

## What already exists in the repo

- `docker-compose.yml` + `Dockerfile` — FrankenPHP + SQLite + Caddy
- `docker-compose.prod.yml` + `Caddyfile` — automatic HTTPS via Let's Encrypt once a domain is set
- `scripts/backup-offbox.sh` — rclone-based off-box copy, tested against MinIO
- `scripts/tls-local-up.sh` — local self-signed HTTPS for testing
- Token hashing at rest, idempotency keys, rate limiting — all shipped

No new code needed. This is a deployment, not a feature.

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

## Setup steps (once a provider is picked)

1. Provision VPS, Ubuntu 22.04 or 24.04
2. Point a subdomain at the VPS IP (e.g. `scan.vuuro.nl`)
   - DuckDNS free subdomain also works for a pilot
3. Clone repo, `cd scan-service`
4. Copy `.env.example` to `.env`, set:
   - `SCAN_SERVICE_ENV=production`
   - `SCAN_SERVICE_ADMIN_API_KEY=<random 32+ chars>`
   - `SCAN_SERVICE_EXPORT_SECRET=<random 32+ chars>`
   - `SCAN_SERVICE_DOMAIN=scan.vuuro.nl`
   - `SCAN_SERVICE_PUBLIC_BASE_URL=https://scan.vuuro.nl`
   - `SCAN_SERVICE_RETENTION_DAYS_CHECK_OUT=30` (and others per `.env.example`)
5. `docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d`
6. Verify: `curl https://scan.vuuro.nl/health` returns 200
7. Set up off-box backup:
   - Create Cloudflare R2 bucket (10 GB free) or Backblaze B2 (10 GB free)
   - `rclone config` with the bucket credentials
   - `export SCAN_SERVICE_BACKUP_REMOTE=r2:vuuro-scan-backups`
   - Test: `sh scripts/backup-offbox.sh`
   - Add to crontab: `0 3 * * *` per `scripts/backup-offbox.cron.example`
8. Point the iOS app at `https://scan.vuuro.nl`:
   - Change `SCAN_SERVICE_BASE_URL` in `ios-app/project.yml`
   - Rebuild and distribute

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
- Any code change — deployment only

## Preconditions before this is "pilot safe"

- [x] HTTPS available (Caddy + Let's Encrypt)
- [x] Token hashing at rest
- [x] Off-box backup script (tested against MinIO)
- [x] Photo storage on the same volume as the DB (rides with backup)
- [ ] Real domain or DuckDNS subdomain chosen
- [ ] `.env` with real secrets set (not defaults)
- [ ] Off-box backup cron verified once by hand
- [ ] Retention policy decided per purpose (defaults set in `.env.example`)

## Decision needed

Pick a provider and a domain, or say "DuckDNS + Hetzner" and I'll
draft the exact command list as a single shell script.
