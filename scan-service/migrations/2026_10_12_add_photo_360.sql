CREATE TABLE IF NOT EXISTS photo_360 (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    room_id TEXT NOT NULL,
    url TEXT NOT NULL,
    position_x REAL NOT NULL,
    position_z REAL NOT NULL,
    heading_deg REAL NOT NULL,
    captured_at TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_photo_360_idempotency
    ON photo_360 (session_id, idempotency_key);

CREATE INDEX IF NOT EXISTS idx_photo_360_session
    ON photo_360 (session_id);

CREATE INDEX IF NOT EXISTS idx_photo_360_room
    ON photo_360 (session_id, room_id);

CREATE TABLE IF NOT EXISTS tour_asset (
    session_id TEXT PRIMARY KEY,
    glb_path TEXT,
    glb_generated_at TEXT,
    viewer_ready INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
