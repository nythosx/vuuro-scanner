<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';

use VuuroScan\Storage\Database;
use VuuroScan\Storage\DatabaseBackup;

$failures = [];
$checks = 0;

function db_check(string $label, bool $pass, string $detail = ''): void
{
    global $failures, $checks;
    $checks++;
    if ($pass) {
        echo "  [PASS] $label\n";
    } else {
        $failures[] = "$label — $detail";
        echo "  [FAIL] $label — $detail\n";
    }
}

function db_remove_tree(string $dir): void
{
    foreach (array_diff(scandir($dir) ?: [], ['.', '..']) as $entry) {
        $path = $dir . '/' . $entry;
        is_dir($path) ? db_remove_tree($path) : unlink($path);
    }
    rmdir($dir);
}

$dir = sys_get_temp_dir() . '/vuuro-backup-test-' . bin2hex(random_bytes(4));
mkdir($dir);
$dbPath = $dir . '/scan_service.sqlite';
$backupDir = $dir . '/backups';

try {
    db_check('no database file means no backup', DatabaseBackup::create(Database::connect(':memory:'), $dbPath) === null);

    $db = Database::connect($dbPath);
    $db->exec("INSERT INTO scan_sessions (id, property_id, unit_id, organisation_id, purpose, created_at, access_token) VALUES ('s-1', 'p', 'u', 'o', 'listing', '2026-10-07T03:00:00+00:00', 'x')");

    $first = DatabaseBackup::create($db, $dbPath);
    db_check('the first backup is written', $first !== null && is_file($first), (string) $first);
    db_check('the backup is a SQLite database', $first !== null && file_get_contents($first, false, null, 0, 15) === 'SQLite format 3');
    $copy = $first !== null ? new PDO('sqlite:' . $first) : null;
    db_check('the backup holds the session', $copy !== null && $copy->query("SELECT COUNT(*) FROM scan_sessions WHERE id = 's-1'")->fetchColumn() == 1);
    $copy = null;

    db_check('a second backup within a day is skipped', DatabaseBackup::create($db, $dbPath) === null);

    $db->exec("INSERT INTO scan_sessions (id, property_id, unit_id, organisation_id, purpose, created_at, access_token) VALUES ('s-2', 'p', 'u', 'o', 'listing', '2026-10-07T03:00:01+00:00', 'x')");
    foreach (glob($backupDir . '/*.sqlite') ?: [] as $existing) {
        unlink($existing);
    }
    $forced = DatabaseBackup::create($db, $dbPath, true);
    db_check('a forced backup is written within the day', $forced !== null && is_file($forced));
    $copy = $forced !== null ? new PDO('sqlite:' . $forced) : null;
    db_check('the forced backup has the newest data', $copy !== null && (int) $copy->query('SELECT COUNT(*) FROM scan_sessions')->fetchColumn() === 2);
    $copy = null;
    $again = DatabaseBackup::create($db, $dbPath, true);
    db_check('a second forced backup right away still succeeds', $again !== null && is_file($again), (string) $again);

    for ($i = 1; $i <= DatabaseBackup::MAX_KEPT + 3; $i++) {
        file_put_contents(sprintf('%s/202601%02dT030000Z.sqlite', $backupDir, $i), 'SQLite format 3');
    }
    DatabaseBackup::create($db, $dbPath, true);
    $kept = glob($backupDir . '/*.sqlite') ?: [];
    sort($kept);
    db_check('only the newest ' . DatabaseBackup::MAX_KEPT . ' backups are kept', count($kept) === DatabaseBackup::MAX_KEPT, (string) count($kept));
    db_check('the oldest backups are the ones removed', !is_file($backupDir . '/20260101T030000Z.sqlite') && in_array($forced, $kept, true));

    $db = null;
    $tool = PHP_BINARY . ' ' . escapeshellarg(__DIR__ . '/../tools/snapshot-db.php');
    putenv('SCAN_SERVICE_DB_PATH=' . $dbPath);
    foreach (glob($backupDir . '/*.sqlite') ?: [] as $existing) {
        unlink($existing);
    }
    $output = [];
    exec($tool . ' 2>&1', $output, $exit);
    $name = trim(implode("\n", $output));
    db_check('the snapshot tool exits 0', $exit === 0, implode(' ', $output));
    db_check('the snapshot tool prints the file it wrote', preg_match('/^\d{8}T\d{6}Z\.sqlite$/', $name) === 1 && is_file($backupDir . '/' . $name), $name);

    putenv('SCAN_SERVICE_DB_PATH=' . $dir . '/missing.sqlite');
    $output = [];
    exec($tool . ' 2>&1', $output, $exit);
    db_check('the snapshot tool exits 3 without a database', $exit === 3, implode(' ', $output));
    db_check('and does not create one', !is_file($dir . '/missing.sqlite'));
} finally {
    putenv('SCAN_SERVICE_DB_PATH');
    db_remove_tree($dir);
}

echo "\n" . count($failures) . " failure(s) out of $checks check(s).\n";
if ($failures !== []) {
    fwrite(STDERR, "\nTEST VERDICT: RED\n");
    foreach ($failures as $f) {
        fwrite(STDERR, " - $f\n");
    }
    exit(1);
}

echo "\nTEST VERDICT: GREEN\n";
exit(0);
