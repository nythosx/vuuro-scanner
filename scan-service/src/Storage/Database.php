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
            mkdir($dir, 0750, true);
        }

        $pdo = new PDO('sqlite:' . $path);
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $pdo->exec('PRAGMA foreign_keys = ON;');
        $pdo->exec('PRAGMA journal_mode = WAL;');
        $pdo->exec('PRAGMA synchronous = NORMAL;');
        $pdo->exec('PRAGMA busy_timeout = 5000;');

        $schema = __DIR__ . '/../../migrations/schema.sql';
        if (!is_file($schema)) {
            throw new \RuntimeException("Schema file not found at {$schema}");
        }
        $schemaSql = file_get_contents($schema);
        if ($schemaSql === false || trim($schemaSql) === '') {
            throw new \RuntimeException("Schema file at {$schema} is empty or unreadable");
        }
        $pdo->exec($schemaSql);

        try {
            $pdo->exec("ALTER TABLE scan_sessions ADD COLUMN expires_at TEXT NOT NULL DEFAULT ''");
        } catch (\PDOException $e) {
        }
        try {
            $pdo->exec("ALTER TABLE idempotency_keys ADD COLUMN request_fingerprint TEXT NOT NULL DEFAULT ''");
        } catch (\PDOException $e) {
        }

        return $pdo;
    }
}