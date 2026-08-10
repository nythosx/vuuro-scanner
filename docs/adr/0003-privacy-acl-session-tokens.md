# ADR 0003 — Session access tokens are Phase 3's privacy/ACL step, not a full auth system

Status: decided for this window. Directly closes the gap CLAUDE.md hard constraint #3
and PHASES.md Phase 3 flag: "Privacy/ACL is real... it should already exist from
Phase 1" — it didn't; every endpoint was open to anyone who knew (or guessed, or found
in a log) a `scan_session_id`, which is exactly the "anyone with the link" default hard
constraint #3 forbids.

## Decision

Every session-scoped endpoint except `POST /scan-sessions` now requires an
`X-Scan-Access-Token` header matching that session's `access_token` — a second, random
UUID generated at creation and returned exactly once, in the creation response. A
`scan_session_id` alone is deliberately no longer sufficient to read or write anything.

Two more things are enforced at creation, not later:

- **Consent for occupied units.** `occupied` is now a required boolean on
  `POST /scan-sessions`. If `true`, `consent_obtained` must also be `true` or the
  request is rejected with `403 consent_required`. There is no path to create a session
  for an occupied unit without recording that consent was obtained.
- **Audited access.** Every authorization check — granted or denied — is written to
  `access_log`, retrievable via `GET /scan-sessions/{id}/access-log` (itself gated by
  the same token). Logging only successes would miss exactly the attempts worth
  auditing — an audit trail that can't show a denied attempt isn't one.

## Why a per-session token, not a user/org account system

Building real Vuuro user accounts, organisation membership, and roles is a large,
separate piece of work that depends on how Vuuro API coupling actually happens — a
decision CLAUDE.md explicitly defers ("auth shape of the Scan Service API" is listed as
open, mine to shape, not yet decided). Blocking all privacy/ACL progress on that larger
system arriving first would mean shipping Phase 3 with the hard-constraint-#3 gap left
open for longer, which is a worse trade than shipping a real, narrower control now.

A per-session token is a real access control, not a placeholder:

- It closes the actual "anyone with the link" gap named in the constraint.
- It doesn't invent an account/identity model that would likely be thrown away once
  real Vuuro auth exists — it's a capability token scoped to exactly one session, which
  composes fine underneath a future account system (a logged-in Vuuro user's client
  would simply hold and present the token for the sessions they created, the same way
  it does today).

## What this explicitly does NOT solve (tracked, not hidden)

- **No real user/org authentication.** Anyone who creates a session gets full control
  of it — there's no login, no verification that the caller is actually a member of
  `organisation_id`. Tenant *isolation* between different organisations' data is not
  enforced by this token model; only per-session possession is.
- **No token rotation or expiry.** A leaked token grants access indefinitely. Real
  token lifecycle (expiry, rotation, revocation) is bigger scope than this window.
- **No transport security guarantee.** This repo runs over plain HTTP locally
  (`scan-service/README.md`). A token model is meaningless without TLS in any real
  deployment — that's a deployment-time requirement to enforce later, not something
  this ADR claims to have solved.

## Follow-up (not blocking, tracked for when Vuuro API coupling becomes a live decision)

Replace/augment the per-session token with real Vuuro account auth once the coupling
shape is decided (CLAUDE.md: "when we couple, we couple through the contract"). The
audit log and consent-gate mechanics here should carry forward largely unchanged; only
the "how is the caller identified" layer needs to change.
