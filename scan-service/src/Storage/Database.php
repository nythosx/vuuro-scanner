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

        $schema = __DIR__ . '/../../migrations/schema.sql';
        $pdo->exec((string) file_get_contents($schema));

        return $pdo;
    }
}
