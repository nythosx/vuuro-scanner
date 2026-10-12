# Project Status

Last updated: 2026-09-26

## What's built and tested

- Single-room LiDAR capture (RoomPlan) with live HUD, wall count, area, height
- Multi-room capture with fusion solver (rotation + translation), overlap detection, walkthrough recovery
- Room-type guessing (live) and post-capture confirmation and renaming
- Object detection display, per-object rename, exclude, delete
- Notes and photos per room, per-item delete, per-note inspection tags
- Export: PNG, SVG, PDF, signed `.vuuroscan` bundle
- Export styles: Full report (metrics + notes) vs Listing plan (clean sheet)
- Homes overview grouped by property and unit, per-floor room counts and areas
- History with search, filter, per-scan nickname, share code, access log
- Read-only report screen for landlord/ops use
- Localization (English + Dutch), String Catalog based, runtime switch
- Admin web panel (read-only): lookup, session detail, exports, imports, retention
- Server: idempotency keys, rate limiting, token hashing at rest, HMAC bundle signing, off-box backups via rclone
- Tenant self-service deletion request with 7-day grace period, status read-back and cancel
- Notes-only fallback for phones without LiDAR

## What's tested but not device-verified

Anything iOS-side that requires RoomPlan or a real iPhone. See individual Ready-to-test notes for per-feature status.

## What's deliberately out of scope for now

- Individual user accounts (per-session tokens only)
- Server-side legal agreement proof (local-only, documented in ADR 0006)
- Real-time analytics or telemetry
- Multi-tenant org isolation
- Production TLS and hosted deployment (spec on request)

## Known gaps

- iOS object edits are only held in `@State` on the fresh result screen; the saved-report screen is the durable editor
- Share codes embed the full access token; revocation is via explicit rotate-token button, not automatic
- PDF text rendering strips non-ASCII glyphs; metrics and identifiers are ASCII-transliterated

## Decisions recorded 2026-09-26

- **Inspection tag vocabulary** — 8-value enum shipped, UI picker live.
- **Export style default** — Full report. Listing plan is opt-in.
- **Homes entry point** — "Add to latest scan" is primary.
- **Share revocation** — explicit "Revoke previous shares" button, Option (b).
- **Retention defaults** — `check_out` 30d, `listing` 90d, `check_in` 365d, `renovation` 365d, `other` 180d.
- **Tenant self-service delete** — 7-day grace period, admin-auditable.
- **Notes-only fallback** — available on phones without LiDAR.
- **Terms/Privacy proof** — stays local-only for the pilot. See ADR 0006 amendment.

## Pending on operator

- Hosted Scan Service provider and domain (spec in `docs/hosting-spec.md`).
- Real legal review of Terms of Service and Privacy Policy text.
- Real-device verification of the current build (Mark).
