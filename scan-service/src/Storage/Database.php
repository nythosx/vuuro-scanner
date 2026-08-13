<?php

declare(strict_types=1);

namespace VuuroScan\Storage;

use PDO;

final class Database
{
    public static function connect(?string $path = null): PDO
    {
        $path ??= getenv('SCAN_SERVICE_DB_PATH') ?: __DIR__ . '/../../data/scan_service.sqlite';
        $dir = dirname($path);
        if (!is_dir($dir)) {
            // 0750, not 0777 (manual security review finding): this
            // directory holds privacy-sensitive interior-scan data —
            // property/unit/org identifiers, capture geometry, access
            // tokens, and the audit log — hard constraint #3 territory.
            // World-writable/readable has no legitimate use here. No effect
            // on Windows (this is a POSIX mode), but matters the moment
            // this runs on a shared Linux host.
            mkdir($dir, 0750, true);
        }

        $pdo = new PDO('sqlite:' . $path);
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $pdo->exec('PRAGMA foreign_keys = ON;');
        // Concurrency hardening (found by deliberately probing the adjacent
        // case to the idempotency-claim race fix: what about two genuinely
        // DIFFERENT concurrent writes to the same session, e.g. two captures
        // with no shared Idempotency-Key, or a capture racing a photo
        // attach?). Without this, a connection that loses a BEGIN IMMEDIATE
        // race (see ScanSessionRepository::withWriteLock) gets an immediate
        // SQLITE_BUSY exception instead of waiting briefly for the winner to
        // commit — under real PHP-FPM concurrency that would turn a normal,
        // momentary write overlap into a spurious 500 for the second caller.
        // 5s is generous next to a single read-modify-write cycle
        // (milliseconds) and small next to any real HTTP client timeout.
        $pdo->exec('PRAGMA busy_timeout = 5000;');

        $schema = __DIR__ . '/../../migrations/schema.sql';
        $pdo->exec((string) file_get_contents($schema));

        // CREATE TABLE IF NOT EXISTS in schema.sql only creates scan_sessions
        // on a fresh database — it does nothing to a scan_sessions table that
        // already existed before the expires_at column was added. SQLite has
        // no "ADD COLUMN IF NOT EXISTS", so this is the idempotent equivalent:
        // try the ALTER TABLE, swallow the "duplicate column" failure on
        // every run after the first. Safe for this local-dev-only SQLite file
        // (scan-service/data/, gitignored) — a real migration tool would
        // replace this the moment there's a shared/deployed database to
        // migrate carefully instead of just re-running schema.sql.
        try {
            $pdo->exec("ALTER TABLE scan_sessions ADD COLUMN expires_at TEXT NOT NULL DEFAULT ''");
        } catch (\PDOException $e) {
            // Expected on every run after the first — the column already exists.
        }
        try {
            $pdo->exec("ALTER TABLE idempotency_keys ADD COLUMN request_fingerprint TEXT NOT NULL DEFAULT ''");
        } catch (\PDOException $e) {
            // Expected on every run after the first — the column already exists.
        }

        return $pdo;
    }
}
