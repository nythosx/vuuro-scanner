<?php

declare(strict_types=1);

require_once __DIR__ . '/../src/autoload.php';
require_once __DIR__ . '/../net/photo_360_repository.php';

use VuuroScan\Storage\Database;

$failures = 0;

function expect($label, $actual, $expected)
{
    global $failures;
    if ($actual !== $expected) {
        fwrite(STDERR, "FAIL $label\n  expected: " . var_export($expected, true) . "\n  actual:   " . var_export($actual, true) . "\n");
        $failures++;
    } else {
        echo "PASS $label\n";
    }
}

$pdo = Database::connect(':memory:');
$pdo->exec(file_get_contents(__DIR__ . '/../migrations/2026_10_12_add_photo_360.sql'));

$repo = new Photo360Repository($pdo);

$first = $repo->insert('s-1', 'r-1', '/photo-uploads/a.jpg', 1.2, 3.4, 90.0, '2026-10-12T10:00:00+00:00', 'key-1');
expect('insert returns room_id', $first['room_id'] ?? null, 'r-1');
expect('insert returns position_x', (float)($first['position_x'] ?? 0), 1.2);
expect('insert returns heading_deg', (float)($first['heading_deg'] ?? 0), 90.0);

$repo->insert('s-1', 'r-1', '/photo-uploads/b.jpg', 2.0, 3.0, 180.0, '2026-10-12T10:01:00+00:00', 'key-2');
$repo->insert('s-1', 'r-2', '/photo-uploads/c.jpg', 0.5, 0.5, 0.0, '2026-10-12T10:02:00+00:00', 'key-3');

expect('listBySession count', count($repo->listBySession('s-1')), 3);
expect('listByRoom r-1 count', count($repo->listByRoom('s-1', 'r-1')), 2);
expect('listByRoom r-2 count', count($repo->listByRoom('s-1', 'r-2')), 1);
expect('countByRoom r-2', $repo->countByRoom('s-1', 'r-2'), 1);
expect('countByRoom missing room', $repo->countByRoom('s-1', 'r-9'), 0);

$duplicate = $repo->findByIdempotencyKey('s-1', 'key-1');
expect('idempotency hit returns same id', (int)($duplicate['id'] ?? -1), (int)($first['id'] ?? -2));
expect('idempotency miss returns null', $repo->findByIdempotencyKey('s-1', 'missing-key'), null);
expect('idempotency scoped by session', $repo->findByIdempotencyKey('s-2', 'key-1'), null);

$serialized = $repo->serialize($first);
expect('serialize photo_id is string', $serialized['photo_id'], (string)$first['id']);
expect('serialize room_id', $serialized['room_id'], 'r-1');
expect('serialize url', $serialized['url'], '/photo-uploads/a.jpg');
expect('serialize position_m', $serialized['position_m'], [1.2, 3.4]);
expect('serialize heading_deg', $serialized['heading_deg'], 90.0);
expect('serialize captured_at', $serialized['captured_at'], '2026-10-12T10:00:00+00:00');
expect('serialize zoom defaults to 1.0', $serialized['zoom'], 1.0);

$zoomed = $repo->insert('s-3', 'r-1', '/photo-uploads/z.jpg', 1.0, 1.0, 0.0, '2026-10-12T10:04:00+00:00', 'key-z', 1.75);
expect('serialize zoom keeps the stored value', $repo->serialize($zoomed)['zoom'], 1.75);
expect('serialize pitch_deg defaults to 0.0', $serialized['pitch_deg'], 0.0);

$tilted = $repo->insert('s-3', 'r-1', '/photo-uploads/t.jpg', 1.0, 1.0, 0.0, '2026-10-12T10:05:00+00:00', 'key-t', 1.0, -12.5);
expect('serialize pitch_deg keeps the stored tilt', $repo->serialize($tilted)['pitch_deg'], -12.5);

expect('serializeList count', count($repo->serializeList($repo->listBySession('s-1'))), 3);
expect('serializedForSession count', count($repo->serializedForSession('s-1')), 3);

$uniqueViolation = false;
try {
    $repo->insert('s-1', 'r-1', '/photo-uploads/dup.jpg', 0.0, 0.0, 0.0, '2026-10-12T10:03:00+00:00', 'key-1');
} catch (PDOException $e) {
    $uniqueViolation = true;
}
expect('unique idempotency enforced', $uniqueViolation, true);

expect('deleteBySession returns count', $repo->deleteBySession('s-1'), 3);
expect('post-delete list empty', $repo->listBySession('s-1'), []);
expect('deleteBySession on empty is zero', $repo->deleteBySession('s-1'), 0);

echo "\n== Phase 1 fields ==\n";
$withStand = $repo->insert('s-lidar47', 'r-1', '/photo-uploads/stand.jpg', 1.0, 2.0, 90.0, '2026-10-27T10:00:00+00:00', 'key-stand', 1.0, 0.0, 'stand-abc123', '[1,0,0,0,0,1,0,0,0,0,1,0,0.5,1.4,2.0,1]', '[800.5,800.5,320.0,240.0]', 'https://scan.test/scan-sessions/s-lidar47/photo-uploads/stand.depth');
$standSerialized = $repo->serialize($withStand);
expect('serialize stand_id preserved', $standSerialized['stand_id'], 'stand-abc123');
expect('serialize has_depth true', $standSerialized['has_depth'], true);
expect('serialize camera_transform is 16-array', is_array($standSerialized['camera_transform']) && count($standSerialized['camera_transform']) === 16, true);
expect('serialize intrinsics is 4-array', is_array($standSerialized['intrinsics']) && count($standSerialized['intrinsics']) === 4, true);
expect('serialize omits depth_url', isset($standSerialized['depth_url']), false);

$withoutNew = $repo->insert('s-lidar47', 'r-1', '/photo-uploads/plain.jpg', 2.0, 3.0, 180.0, '2026-10-27T10:01:00+00:00', 'key-plain');
$plainSerialized = $repo->serialize($withoutNew);
expect('serialize no stand_id defaults to empty', $plainSerialized['stand_id'], '');
expect('serialize has_depth false', $plainSerialized['has_depth'], false);
expect('serialize camera_transform null', $plainSerialized['camera_transform'], null);
expect('serialize intrinsics null', $plainSerialized['intrinsics'], null);

if ($failures > 0) {
    fwrite(STDERR, "\n$failures failure(s)\n");
    exit(1);
}
echo "All photo_360_repository tests passed.\n";
