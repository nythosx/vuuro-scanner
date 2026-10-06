<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';

use VuuroScan\Storage\Database;

$baseUrl = rtrim(getenv('SCAN_SERVICE_RESTORE_CHECK_URL') ?: 'http://127.0.0.1:8089', '/');
$adminKey = (string) getenv('SCAN_SERVICE_ADMIN_API_KEY');
$dbPath = Database::resolvePath();
$photosRoot = __DIR__ . '/../data/photos';

function restoreCheckFail(string $message): never
{
    fwrite(STDERR, "restore-check: $message\n");
    exit(1);
}

function restoreCheckGet(string $url, string $adminKey): array
{
    $context = stream_context_create(['http' => [
        'method' => 'GET',
        'header' => "X-Admin-Api-Key: $adminKey\r\n",
        'ignore_errors' => true,
        'timeout' => 10,
    ]]);
    $body = @file_get_contents($url, false, $context);
    $headers = function_exists('http_get_last_response_headers') ? (http_get_last_response_headers() ?? []) : ($http_response_header ?? []);
    $status = preg_match('#^HTTP/\S+\s+(\d{3})#', (string) ($headers[0] ?? ''), $m) ? (int) $m[1] : 0;
    return [$status, $body === false ? '' : $body];
}

if ($adminKey === '') {
    restoreCheckFail('SCAN_SERVICE_ADMIN_API_KEY is not set inside the container');
}
if (!is_file($dbPath)) {
    restoreCheckFail("no database at $dbPath");
}

$db = new PDO('sqlite:' . $dbPath);
$db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
$integrity = (string) $db->query('PRAGMA integrity_check')->fetchColumn();
if ($integrity !== 'ok') {
    restoreCheckFail("the database failed its integrity check: $integrity");
}
$sessionCount = (int) $db->query('SELECT COUNT(*) FROM scan_sessions')->fetchColumn();
echo "sessions in the database: $sessionCount\n";
if ($sessionCount === 0) {
    restoreCheckFail('the restored database has no sessions');
}

$known = $db->prepare('SELECT 1 FROM scan_sessions WHERE id = ?');
$photoFiles = 0;
$orphans = 0;
foreach (glob($photosRoot . '/*', GLOB_ONLYDIR) ?: [] as $dir) {
    $files = array_filter(glob($dir . '/*') ?: [], 'is_file');
    $photoFiles += count($files);
    $known->execute([basename($dir)]);
    if ($known->fetchColumn() === false) {
        $orphans++;
    }
}
echo "photo files on disk: $photoFiles\n";
if ($orphans > 0) {
    echo "photo folders without a session in this database: $orphans (normal when the database copy is older than the photos)\n";
}

$sessionIds = $db->query('SELECT id FROM scan_sessions ORDER BY created_at DESC, rowid DESC')->fetchAll(PDO::FETCH_COLUMN);
$withPhoto = null;
$photoFile = null;
foreach ($sessionIds as $candidate) {
    $files = array_values(array_filter(glob($photosRoot . '/' . $candidate . '/*') ?: [], 'is_file'));
    if ($files !== []) {
        $withPhoto = (string) $candidate;
        $photoFile = $files[0];
        break;
    }
}
$checkId = $withPhoto ?? (string) $sessionIds[0];

[$status] = restoreCheckGet("$baseUrl/scan-sessions/$checkId", $adminKey);
if ($status !== 200) {
    restoreCheckFail("reading session $checkId through the API returned HTTP $status");
}
echo "session $checkId reads back through the API\n";

if ($photoFile !== null) {
    $name = basename($photoFile);
    [$photoStatus, $photoBody] = restoreCheckGet("$baseUrl/scan-sessions/$checkId/photo-uploads/$name", $adminKey);
    if ($photoStatus !== 200 || strlen($photoBody) !== filesize($photoFile)) {
        restoreCheckFail("photo $name of session $checkId did not come back through the API (HTTP $photoStatus)");
    }
    echo "photo $name of that session comes back through the API\n";
} else {
    echo "no session in this database has photos on disk, so no photo was checked\n";
}

echo "restore-check: OK\n";
exit(0);
