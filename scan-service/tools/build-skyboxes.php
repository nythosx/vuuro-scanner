<?php

declare(strict_types=1);

require_once __DIR__ . '/../src/autoload.php';

use VuuroScan\Export\StandSkyboxStore;
use VuuroScan\Export\TourStands;
use VuuroScan\ScanSessionRepository;
use VuuroScan\Storage\Database;

if ($argc < 2) {
    fwrite(STDERR, "Usage: php tools/build-skyboxes.php <scan-session-id>\n");
    exit(2);
}

$sessionId = $argv[1];
$repo = new ScanSessionRepository(Database::connect());
$floorPlan = $repo->findFloorPlan($sessionId);
if ($floorPlan === null) {
    fwrite(STDERR, "No floor plan for session {$sessionId}.\n");
    exit(1);
}

$photosByRoom = [];
foreach ($floorPlan['photos_360'] ?? [] as $photo) {
    $photosByRoom[(string) $photo['room_id']][] = $photo;
}
$rooms = [];
foreach ($floorPlan['rooms'] as $room) {
    $room['photos'] = $photosByRoom[(string) $room['room_id']] ?? [];
    $rooms[] = $room;
}
$stands = TourStands::compute($rooms)['stands_by_room'];

$photoDir = __DIR__ . '/../data/photos/' . $sessionId . '/';
$photoPath = static function (string $url) use ($sessionId, $photoDir): ?string {
    $path = parse_url($url, PHP_URL_PATH);
    $prefix = "/scan-sessions/{$sessionId}/photo-uploads/";
    if (!is_string($path) || !str_starts_with($path, $prefix)) {
        return null;
    }
    $name = substr($path, strlen($prefix));
    return preg_match('#^[a-f0-9\-]+\.(?:jpg|png|webp)$#', $name) === 1 && is_file($photoDir . $name) ? $photoDir . $name : null;
};

$store = new StandSkyboxStore(__DIR__ . '/../data/skybox');
$plan = $store->plan($sessionId, $stands, $photosByRoom, $photoPath);
$readyCount = 0;
foreach ($plan['ready'] as $readyStands) {
    $readyCount += count($readyStands);
}
echo "Ready: {$readyCount}, to build: " . count($plan['pending']) . "\n";
$failed = 0;
foreach ($plan['pending'] as $item) {
    $started = microtime(true);
    $ok = $store->build($sessionId, $item['room_id'], $item['stand_id'], $item['key'], $item['photos'], $photoPath);
    printf("  %s %s/%s (%d photos, %.1fs)\n", $ok ? 'built' : 'FAILED', $item['room_id'], $item['stand_id'], count($item['photos']), microtime(true) - $started);
    $failed += $ok ? 0 : 1;
}
exit($failed > 0 ? 1 : 0);
