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
    consent_obtained INTEGER NOT NULL DEFAULT 0
);

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
