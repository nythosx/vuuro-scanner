CREATE TABLE IF NOT EXISTS scan_sessions (
    id TEXT PRIMARY KEY,
    property_id TEXT NOT NULL,
    unit_id TEXT NOT NULL,
    organisation_id TEXT NOT NULL,
    purpose TEXT NOT NULL,
    created_at TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'created'
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
