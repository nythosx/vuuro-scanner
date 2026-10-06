<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';

use VuuroScan\Storage\Database;
use VuuroScan\Storage\DatabaseBackup;

$dbPath = Database::resolvePath();
if (!is_file($dbPath)) {
    fwrite(STDERR, "snapshot-db: no database at $dbPath\n");
    exit(3);
}

$path = DatabaseBackup::create(Database::connect($dbPath), $dbPath, true);
if ($path === null || !is_file($path)) {
    fwrite(STDERR, "snapshot-db: the snapshot could not be written next to $dbPath\n");
    exit(1);
}

echo basename($path), "\n";
exit(0);
