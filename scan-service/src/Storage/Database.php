<?php

declare(strict_types=1);

namespace VuuroScan\Storage;

use PDO;

final class Database
{
    public static function resolvePath(): string
    {
        return getenv('SCAN_SERVICE_DB_PATH') ?: __DIR__ . '/../../data/scan_service.sqlite';
    }

    public static function connect(?string $path = null): PDO
    {
        $path ??= self::resolvePath();
        $dir = dirname($path);
        if (!is_dir($dir)) {
            // 0750, not 0777: this directory holds privacy-sensitive
            // interior-scan data — property/unit/org identifiers, capture
            // geometry, access tokens, and the audit log.
            mkdir($dir, 0750, true);
        }

        $pdo = new PDO('sqlite:' . $path);
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $pdo->exec('PRAGMA foreign_keys = ON;');
        // Without this, a connection that loses a BEGIN IMMEDIATE race (see
        // ScanSessionRepository::withWriteLock) gets an immediate
        // SQLITE_BUSY exception instead of waiting briefly for the winner to
        // commit. 5s is generous next to a single read-modify-write cycle
        // and small next to any real HTTP client timeout.
        $pdo->exec('PRAGMA busy_timeout = 5000;');

        $schema = __DIR__ . '/../../migrations/schema.sql';
        $pdo->exec((string) file_get_contents($schema));

        // SQLite has no "ADD COLUMN IF NOT EXISTS" — this is the idempotent
        // equivalent: try the ALTER TABLE, swallow the "duplicate column"
        // failure on every run after the first. Safe for this local-dev-only
        // SQLite file (scan-service/data/, gitignored) — a real migration
        // tool would replace this the moment there's a shared/deployed
        // database to migrate carefully instead of just re-running schema.sql.
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
