<?php

declare(strict_types=1);

require_once __DIR__ . '/../src/autoload.php';

use VuuroScan\Export\LidarModelKtx2;
use VuuroScan\Export\LidarModelStore;

$sessionId = $argv[1] ?? '';
if (!is_string($sessionId) || preg_match('/^[a-zA-Z0-9\-]{1,80}$/', $sessionId) !== 1) {
    fwrite(STDERR, "Usage: php tools/encode-lidar-ktx2.php <session id>\n");
    exit(2);
}
$toktx = LidarModelKtx2::encoder();
if ($toktx === null) {
    fwrite(STDERR, "toktx is not installed, so the photos stay JPEG.\n");
    exit(1);
}
$root = getenv('SCAN_SERVICE_LIDAR_MODEL_DIR');
$store = new LidarModelStore(is_string($root) && $root !== '' ? $root : __DIR__ . '/../data/lidar-model');
$result = $store->buildKtx2($sessionId, $toktx);
if (!$result['ok']) {
    fwrite(STDERR, "KTX2 for $sessionId failed: {$result['message']}\n");
    exit(1);
}
echo "KTX2 for $sessionId: {$result['photos']} photos, {$result['bytes']} bytes, {$result['seconds']} s\n";
