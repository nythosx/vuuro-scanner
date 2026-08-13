CREATE TABLE IF NOT EXISTS scan_sessions (
    id TEXT PRIMARY KEY,
    property_id TEXT NOT NULL,
    unit_id TEXT NOT NULL,
    organisation_id TEXT NOT NULL,
    purpose TEXT NOT NULL,
    created_at TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'created',
    -- Privacy/ACL (hard constraint #3). access_token is the credential every
    -- read/write to this session must present — knowing `id` (which can leak
    -- via URLs/logs) is deliberately not sufficient on its own, so there is
    -- no "anyone with the link" default. occupied/consent_obtained enforce
    -- that an occupied unit cannot be captured without recorded consent.
    access_token TEXT NOT NULL,
    occupied INTEGER NOT NULL DEFAULT 0,
    consent_obtained INTEGER NOT NULL DEFAULT 0,
    -- Enterprise hardening: token lifecycle (docs/adr/0003 flagged "no token
    -- rotation/expiry" as a known limit). expires_at is set at creation from
    -- either a caller-supplied access_token_ttl_seconds or a 90-day default,
    -- and refreshed on every POST .../rotate-token call.
    expires_at TEXT NOT NULL DEFAULT ''
);

-- Idempotency for POST .../capture (enterprise reliability hardening): a
-- mobile client retrying an upload after a dropped response on flaky
-- on-site connectivity must not append the same room twice. One row per
-- (session, key) pair; a repeat key within the same session replays the
-- stored response instead of re-running the adapter.
CREATE TABLE IF NOT EXISTS idempotency_keys (
    scan_session_id TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    response_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    -- Adjacent-case fix: a key reused with a genuinely different request body
    -- (client bug, or two distinct rooms captured under the same key) used to
    -- silently replay the FIRST cached response instead of processing the new
    -- one — the fix that prevents double-append on a true retry was silently
    -- dropping real capture data on a key collision. sha256 of the fields
    -- that define "the same request", set once at claim time and compared on
    -- every subsequent lookup under this key.
    request_fingerprint TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (scan_session_id, idempotency_key)
);

-- Fixed-window rate limiting (enterprise hardening): scan-service/README.md
-- "Known limits" flagged unlimited session creation as accepted-for-now risk
-- for a local-dev-only window. bucket is caller-IP + route, so different
-- routes/callers get independent windows.
CREATE TABLE IF NOT EXISTS rate_limit_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    bucket TEXT NOT NULL,
    occurred_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_rate_limit_events_bucket ON rate_limit_events(bucket, occurred_at);

-- One row per session. Phase 1 is single-room; Phase 2 (multi-room stitching)
-- is expected to still key on scan_session_id, not add a new identity axis.
CREATE TABLE IF NOT EXISTS floor_plans (
    scan_session_id TEXT PRIMARY KEY REFERENCES scan_sessions(id),
    capture_provider TEXT NOT NULL,
    captured_at TEXT NOT NULL,
    measurement_basis TEXT NOT NULL,
    contract_json TEXT NOT NULL
);

-- Audited access (hard constraint #3): every attempt to read or write a
-- session is recorded, including denied ones — an audit trail that only
-- logs successes would miss exactly the attempts worth auditing.
CREATE TABLE IF NOT EXISTS access_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    scan_session_id TEXT NOT NULL,
    action TEXT NOT NULL,
    outcome TEXT NOT NULL,
    occurred_at TEXT NOT NULL
);
