# 0003. Per-session access tokens, consent, and audit log

## Status

Accepted. `ROTATE_GRACE_PERIOD_SECONDS` confirmed with Mark 2026-08-14.

## Context

The brief treats privacy as a first-design concern, not a later cleanup: occupied-unit
consent and tenant-scoped storage need to exist from the start (root `README.md`'s
"Principles"). There is no Vuuro account/login system for this build to couple to yet —
that's a future integration, not something to build ahead of need.

## Decision

**Consent gate at creation**: `POST /scan-sessions` with `occupied: true` requires
`consent_obtained: true`, or the request is rejected (`403 consent_required`). No path
exists to create a session for an occupied unit without recording consent.

**Per-session capability token**, not an account system: a random UUID access token,
returned once at session creation, required via `X-Scan-Access-Token` on every
session-scoped route after creation. Compared everywhere with `hash_equals()`, never a
plain `===`.

**Token lifetime**: `DEFAULT_TOKEN_TTL_SECONDS` = 90 days, bounded between
`MIN_TOKEN_TTL_SECONDS` (60 seconds) and `MAX_TOKEN_TTL_SECONDS` (365 days). A caller
can rotate before or shortly after expiry via `rotate-token`, within a
`ROTATE_GRACE_PERIOD_SECONDS` window of 7 days past expiry — confirmed as an acceptable
default with Mark on 2026-08-14. Past that grace window, rotation is refused and a new
session is the only path forward.

**Audit log**: the `access_log` table records `action`/`outcome`/`occurred_at` only —
never the token itself, never the caller's IP. Exposed in-app read-only via
`ios-app/Sources/History/AccessLogView.swift` and `GET .../access-log`.

**Rate-limit event retention**: `RATE_LIMIT_EVENT_RETENTION_SECONDS` = 3600 (1 hour) —
old rate-limit bucket events are pruned on write, not kept indefinitely.

## Consequences — what this deliberately does and doesn't solve

Solves: the "anyone with the link" gap (possession of the correct token is required,
compared safely); consent-before-capture for occupied units; an audit trail an occupant
or Vuuro can review without exposing the token or caller IP; a bounded, rotatable token
lifetime instead of a permanent secret.

Does **not** solve, on purpose, for this build's window:
- No login, no Vuuro user/org account system. Designed to compose *underneath* a future
  account system once Vuuro API coupling is decided — not to be replaced wholesale (see
  root `README.md`'s roadmap, "Real Vuuro account auth").
- No tenant isolation beyond per-session possession of the token — there's no broader
  organisation-level access control model yet.
- No transport security guarantee. This repo runs over plain HTTP locally; a real
  deployment needs TLS in front of it, which this ADR does not claim to have solved.
- On the iOS side, `ios-app/Sources/History/ScanHistoryStore.swift` stores each
  remembered session's access token in plaintext `UserDefaults`, not the Keychain — a
  known limit flagged in that file's own header, acceptable for this local-pilot
  window, worth fixing before any real deployment.
- No server-side session listing exists by design — history is local-only
  (`ScanHistoryStore`), so there is no "list all sessions for this org" endpoint that
  would need its own access-control model.
