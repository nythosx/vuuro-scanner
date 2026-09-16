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
        $pdo->exec('PRAGMA busy_timeout = 5000;');

        $schema = __DIR__ . '/../../migrations/schema.sql';
        $pdo->exec((string) file_get_contents($schema));

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