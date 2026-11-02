<?php

declare(strict_types=1);

require_once __DIR__ . '/../src/autoload.php';

use VuuroScan\Export\TourReadiness;
use VuuroScan\Export\TourStands;

$failures = 0;

function check(string $label, mixed $actual, mixed $expected): void
{
    global $failures;
    if ($actual !== $expected) {
        fwrite(STDERR, "FAIL $label\n  expected: " . var_export($expected, true) . "\n  actual:   " . var_export($actual, true) . "\n");
        $failures++;
    } else {
        echo "PASS $label\n";
    }
}

function shot(string $id, float $x, float $z, ?string $standId = null, float $heading = 0.0): array
{
    return [
        'photo_id' => $id,
        'position_m' => [$x, $z],
        'heading_deg' => $heading,
        'captured_at' => '2026-11-02T10:00:' . str_pad((string) (crc32($id) % 60), 2, '0', STR_PAD_LEFT) . '+00:00',
        'stand_id' => $standId,
    ];
}

function space(string $id, string $label, array $origin, array $photos, array $openings = [], ?array $entry = null): array
{
    return [
        'room_id' => $id,
        'label' => $label,
        'floor' => 'Ground',
        'structure_origin_m' => $origin,
        'outline_m' => [[0.0, 0.0], [5.0, 0.0], [5.0, 4.0], [0.0, 4.0]],
        'openings' => $openings,
        'entry_doorway_m' => $entry,
        'photos' => $photos,
    ];
}

function statusOf(array $report, string $key): string
{
    foreach ($report['checks'] as $c) {
        if ($c['key'] === $key) {
            return $c['status'];
        }
    }
    return 'missing';
}

function readiness(array $rooms): array
{
    return TourReadiness::compute($rooms, TourStands::compute($rooms)['stands_by_room']);
}

echo "== Distance outside ==\n";
$square = [[0.0, 0.0], [5.0, 0.0], [5.0, 4.0], [0.0, 4.0]];
check('inside point is 0', TourReadiness::distanceOutside([2.0, 2.0], $square), 0.0);
check('point 1 m past the right wall', round(TourReadiness::distanceOutside([6.0, 2.0], $square), 3), 1.0);
check('corner diagonal', round(TourReadiness::distanceOutside([8.0, 8.0], $square), 3), 5.0);

echo "\n== Every position outside (like 62f55e50) ==\n";
$outsidePhotos = [];
for ($i = 0; $i < 31; $i++) {
    $outsidePhotos[] = shot('o' . $i, 11.0 + ($i % 3) * 0.2, 2.0 + ($i % 5) * 0.1, $i < 8 ? 'spot-1' : null, $i * 45.0);
}
$bad = readiness([space('attic', 'Room 1', [0.0, 0.0], $outsidePhotos)]);
check('outside: not ready', $bad['ready'], false);
check('outside: positions check fails', statusOf($bad, 'positions_inside'), 'fail');
check('outside: room counts 0 of 31 inside', [$bad['rooms'][0]['inside'], $bad['rooms'][0]['positioned']], [0, 31]);
check('outside: furthest out is about 6.4 m', $bad['rooms'][0]['max_outside_m'], 6.4);
check('outside: single room needs no door', statusOf($bad, 'door_per_room'), 'n/a');

echo "\n== Good single room ==\n";
$good = readiness([space('attic', 'Room 1', [0.0, 0.0], [
    shot('w1', 1.0, 1.0),
    shot('w2', 4.0, 3.0),
    shot('w3', 5.2, 2.0),
    shot('s1a', 2.0, 2.0, 'spot-1', 0.0),
    shot('s1b', 2.0, 2.0, 'spot-1', 90.0),
    shot('s2a', 3.5, 2.0, 'spot-2', 0.0),
    shot('s2b', 3.5, 2.0, 'spot-2', 90.0),
])]);
check('good: ready', $good['ready'], true);
check('good: 0.2 m outside still counts as inside', [$good['rooms'][0]['inside'], $good['rooms'][0]['positioned']], [7, 7]);
check('good: two spots counted', $good['rooms'][0]['spots'], 2);
check('good: spots connected', statusOf($good, 'connected_spots'), 'pass');

echo "\n== Two rooms, one without photos and without a door ==\n";
$two = readiness([
    space('a', 'Living', [0.0, 0.0], [shot('a1', 1.0, 1.0, 'spot-a', 0.0), shot('a2', 1.0, 1.0, 'spot-a', 90.0)], [[
        'category' => 'door', 'position_m' => [5.0, 2.0],
    ]]),
    space('b', 'Bedroom', [20.0, 0.0], []),
]);
check('two rooms: not ready', $two['ready'], false);
check('two rooms: photos check fails', statusOf($two, 'photos_per_room'), 'fail');
check('two rooms: door check fails', statusOf($two, 'door_per_room'), 'fail');
check('two rooms: Living has a door', $two['rooms'][0]['door'], true);
check('two rooms: Bedroom has no door', $two['rooms'][1]['door'], false);
check('two rooms: lone spot passes', statusOf($two, 'connected_spots'), 'pass');

echo "\n== Entry doorway counts as a door ==\n";
$entry = readiness([
    space('a', 'Hall', [0.0, 0.0], [shot('h1', 1.0, 1.0)], [], [0.0, 2.0]),
    space('b', 'Kitchen', [5.0, 0.0], [shot('k1', 1.0, 1.0)], [['category' => 'door', 'position_m' => [0.0, 2.0]]]),
]);
check('entry doorway: door check passes', statusOf($entry, 'door_per_room'), 'pass');
check('entry doorway: no spots means n/a', statusOf($entry, 'connected_spots'), 'n/a');

echo "\n== Spots far apart in different rooms stay unconnected ==\n";
$far = readiness([
    space('a', 'Living', [0.0, 0.0], [shot('a1', 1.0, 1.0, 'spot-a', 0.0), shot('a2', 1.0, 1.0, 'spot-a', 90.0)], [['category' => 'door', 'position_m' => [5.0, 2.0]]]),
    space('b', 'Loft', [40.0, 0.0], [shot('b1', 1.0, 1.0, 'spot-b', 0.0), shot('b2', 1.0, 1.0, 'spot-b', 90.0)], [['category' => 'door', 'position_m' => [0.0, 2.0]]]),
]);
check('far spots: connected check fails', statusOf($far, 'connected_spots'), 'fail');

echo "\n";
echo $failures === 0 ? "TEST VERDICT: GREEN\n" : "$failures failure(s)\nTEST VERDICT: RED\n";
exit($failures === 0 ? 0 : 1);
