<?php

declare(strict_types=1);

require_once __DIR__ . '/../src/autoload.php';

use VuuroScan\Export\TourStands;

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

function photo(string $photoId, float $x, float $z, float $heading, string $capturedAt, ?string $standId = null): array
{
    return [
        'photo_id' => $photoId,
        'position_m' => [$x, $z],
        'heading_deg' => $heading,
        'captured_at' => $capturedAt,
        'stand_id' => $standId,
    ];
}

function door(float $x, float $z): array
{
    return [
        'opening_id' => 'door-' . $x . '-' . $z,
        'category' => 'door',
        'position_m' => [$x, $z],
        'confidence' => 'high',
    ];
}

function room(string $roomId, ?string $floor, ?array $origin, array $openings, array $photos): array
{
    return [
        'room_id' => $roomId,
        'floor' => $floor,
        'structure_origin_m' => $origin,
        'outline_m' => [[0.0, 0.0], [5.0, 0.0], [5.0, 5.0], [0.0, 5.0]],
        'openings' => $openings,
        'photos' => $photos,
    ];
}

function sortedNeighbours(array $stand): array
{
    $list = $stand['neighbours'];
    usort($list, static fn (array $a, array $b): int => $a['stand_id'] <=> $b['stand_id']);
    return $list;
}

echo "== Clustering ==\n";
$clustering = TourStands::compute([room('room-a', 'Ground', [0.0, 0.0], [], [
    photo('p1', 1.0, 1.0, 0.0, '2026-10-27T10:00:00+00:00'),
    photo('p2', 1.2, 1.1, 45.0, '2026-10-27T10:00:30+00:00'),
    photo('p3', 5.0, 5.0, 90.0, '2026-10-27T10:01:00+00:00'),
])])['stands_by_room']['room-a'];
expect('clustering: two stands', count($clustering), 2);
expect('clustering: first stand has 2 photos', count($clustering[0]['photo_ids']), 2);
expect('clustering: second stand has 1 photo', count($clustering[1]['photo_ids']), 1);

echo "\n== Stored stand_id wins ==\n";
$withStored = TourStands::compute([room('room-a', 'Ground', [0.0, 0.0], [], [
    photo('p1', 0.0, 0.0, 0.0, '2026-10-27T10:00:00+00:00', 'fixed-stand'),
    photo('p2', 10.0, 10.0, 90.0, '2026-10-27T10:01:00+00:00', 'fixed-stand'),
])])['stands_by_room']['room-a'];
expect('stored stand_id: one stand', count($withStored), 1);
expect('stored stand_id: id preserved', $withStored[0]['stand_id'], 'fixed-stand');

echo "\n== Symmetric neighbours ==\n";
$symmetric = TourStands::compute([
    room('room-a', 'Ground', [0.0, 0.0], [door(5.0, 2.0)], [
        photo('pa1', 4.5, 2.0, 0.0, '2026-10-27T10:00:00+00:00'),
    ]),
    room('room-b', 'Ground', [5.0, 0.0], [door(0.0, 2.0)], [
        photo('pb1', 0.5, 2.0, 0.0, '2026-10-27T10:00:05+00:00'),
    ]),
])['stands_by_room'];
$aNeighbours = sortedNeighbours($symmetric['room-a'][0]);
$bNeighbours = sortedNeighbours($symmetric['room-b'][0]);
expect('symmetric: room-a has one neighbour in room-b', count($aNeighbours), 1);
expect('symmetric: room-a neighbour is room-b', $aNeighbours[0]['room_id'], 'room-b');
expect('symmetric: room-b has one neighbour in room-a', count($bNeighbours), 1);
expect('symmetric: room-b neighbour is room-a', $bNeighbours[0]['room_id'], 'room-a');
expect('symmetric: reverse link has same stand', $aNeighbours[0]['stand_id'], $symmetric['room-b'][0]['stand_id']);

echo "\n== No door, no cross-room link ==\n";
$noDoor = TourStands::compute([
    room('room-a', 'Ground', [0.0, 0.0], [], [photo('pa1', 1.0, 1.0, 0.0, '2026-10-27T10:00:00+00:00')]),
    room('room-b', 'Ground', [2.0, 0.0], [], [photo('pb1', 1.0, 1.0, 0.0, '2026-10-27T10:00:05+00:00')]),
])['stands_by_room'];
expect('no door: room-a isolated', $noDoor['room-a'][0]['neighbours'], []);
expect('no door: room-b isolated', $noDoor['room-b'][0]['neighbours'], []);

echo "\n== No cross-floor links ==\n";
$crossFloor = TourStands::compute([
    room('room-a', 'Ground', [0.0, 0.0], [door(5.0, 2.0)], [photo('pa1', 4.5, 2.0, 0.0, '2026-10-27T10:00:00+00:00')]),
    room('room-b', 'Attic', [5.0, 0.0], [door(0.0, 2.0)], [photo('pb1', 0.5, 2.0, 0.0, '2026-10-27T10:00:05+00:00')]),
])['stands_by_room'];
expect('cross-floor: room-a isolated', $crossFloor['room-a'][0]['neighbours'], []);
expect('cross-floor: room-b isolated', $crossFloor['room-b'][0]['neighbours'], []);

echo "\n== Stable stand ids ==\n";
$stableRoom = room('room-a', 'Ground', [0.0, 0.0], [], [
    photo('p1', 0.0, 0.0, 0.0, '2026-10-27T10:00:00+00:00'),
]);
$standBefore = TourStands::compute([$stableRoom])['stands_by_room']['room-a'][0];
$stableRoom['photos'][] = photo('p2', 0.3, 0.3, 90.0, '2026-10-27T10:01:00+00:00');
$standAfter = TourStands::compute([$stableRoom])['stands_by_room']['room-a'][0];
expect('stable id: unchanged after add', $standAfter['stand_id'], $standBefore['stand_id']);
expect('stable id: both photos present', count($standAfter['photo_ids']), 2);

echo "\n== Empty room ==\n";
$empty = TourStands::compute([room('room-a', 'Ground', [0.0, 0.0], [], [])]);
expect('empty: no stands', $empty['stands_by_room']['room-a'], []);
expect('empty: walkthrough false', $empty['walkthrough'], false);

echo "\n== Single-photo room ==\n";
$single = TourStands::compute([room('room-a', 'Ground', [0.0, 0.0], [], [photo('p1', 0.0, 0.0, 0.0, '2026-10-27T10:00:00+00:00')])]);
expect('single: one stand', count($single['stands_by_room']['room-a']), 1);
expect('single: walkthrough false', $single['walkthrough'], false);

echo "\n== Walkthrough flag ==\n";
$twoSingleShotStands = TourStands::compute([room('room-a', 'Ground', [0.0, 0.0], [], [
    photo('p1', 0.0, 0.0, 0.0, '2026-10-27T10:00:00+00:00', 'stand-one'),
    photo('p2', 5.0, 5.0, 90.0, '2026-10-27T10:01:00+00:00', 'stand-two'),
])]);
expect('walkthrough: captured stands with one photo each stay false', $twoSingleShotStands['walkthrough'], false);

$lookAroundPhotos = [];
for ($i = 0; $i < 12; $i++) {
    $lookAroundPhotos[] = photo('p' . $i, 2.0, 2.0, $i * 30.0, sprintf('2026-10-27T10:00:%02d+00:00', $i), 'stand-full');
}
$oneFullStand = TourStands::compute([room('room-a', 'Ground', [0.0, 0.0], [], $lookAroundPhotos)]);
expect('walkthrough: one room with one full look-around stand true', $oneFullStand['walkthrough'], true);

$oneStandPerRoom = TourStands::compute([
    room('room-a', 'Ground', [0.0, 0.0], [], [
        photo('p1', 1.0, 1.0, 0.0, '2026-10-27T10:00:00+00:00', 'stand-a'),
        photo('p2', 1.0, 1.0, 90.0, '2026-10-27T10:00:05+00:00', 'stand-a'),
    ]),
    room('room-b', 'Ground', [5.0, 0.0], [], [photo('p3', 1.0, 1.0, 0.0, '2026-10-27T10:01:00+00:00', 'stand-b')]),
]);
expect('walkthrough: a captured look-around stand in one of two rooms true', $oneStandPerRoom['walkthrough'], true);

echo "\n== Neighbour cap ==\n";
$crowdPhotos = [];
for ($i = 0; $i < 7; $i++) {
    $crowdPhotos[] = photo('c' . $i, 0.5 + $i * 0.6, 0.5 + ($i % 2) * 0.6, 0.0, sprintf('2026-10-27T11:00:%02d+00:00', $i), 'crowd-' . $i);
}
$crowd = TourStands::compute([
    room('room-a', 'Ground', [0.0, 0.0], [door(4.4, 0.0)], $crowdPhotos),
    room('room-b', 'Ground', [0.0, -5.0], [], [photo('b1', 4.4, 4.5, 0.0, '2026-10-27T11:01:00+00:00', 'room-b-stand')]),
])['stands_by_room'];
$maxDegree = 0;
$symmetric = true;
$lookup = [];
foreach ($crowd as $roomId => $stands) {
    foreach ($stands as $stand) {
        $lookup[$stand['stand_id']] = $stand;
    }
}
foreach ($lookup as $standId => $stand) {
    $maxDegree = max($maxDegree, count($stand['neighbours']));
    foreach ($stand['neighbours'] as $neighbour) {
        $back = array_column($lookup[$neighbour['stand_id']]['neighbours'] ?? [], 'stand_id');
        if (!in_array($standId, $back, true)) {
            $symmetric = false;
        }
    }
}
expect('cap: no stand has more than 4 neighbours', $maxDegree <= TourStands::MAX_NEIGHBOURS, true);
expect('cap: links stay symmetric', $symmetric, true);
expect('cap: the door link survives a crowded room', count($crowd['room-b'][0]['neighbours']), 1);

echo "\n== The doorway noted between rooms links their spots ==\n";
$noDoor = TourStands::compute([
    room('room-a', 'Ground', [0.0, 0.0], [], [photo('a1', 4.4, 2.5, 0.0, '2026-10-27T11:00:00+00:00', 'stand-a')]),
    room('room-b', 'Ground', [0.0, -5.0], [], [photo('b1', 4.4, 2.5, 0.0, '2026-10-27T11:01:00+00:00', 'stand-b')]),
])['stands_by_room'];
expect('doorway: without a door the rooms stay unlinked', count($noDoor['room-b'][0]['neighbours']), 0);
$roomB = room('room-b', 'Ground', [0.0, -5.0], [], [photo('b1', 4.4, 2.5, 0.0, '2026-10-27T11:01:00+00:00', 'stand-b')]);
$roomB['entry_doorway_m'] = [4.4, 4.9];
$withDoor = TourStands::compute([
    room('room-a', 'Ground', [0.0, 0.0], [], [photo('a1', 4.4, 2.5, 0.0, '2026-10-27T11:00:00+00:00', 'stand-a')]),
    $roomB,
])['stands_by_room'];
expect('doorway: the noted doorway links the two spots', array_column($withDoor['room-b'][0]['neighbours'], 'stand_id'), ['stand-a']);

echo "\n== Captured stands do not link to wall-photo stands ==\n";
$mixed = TourStands::compute([room('room-a', 'Ground', [0.0, 0.0], [], [
    photo('w1', 1.0, 1.0, 0.0, '2026-10-27T12:00:00+00:00'),
    photo('w2', 4.0, 1.0, 90.0, '2026-10-27T12:00:10+00:00'),
    photo('s1', 2.0, 2.0, 0.0, '2026-10-27T12:01:00+00:00', 'stand-x'),
    photo('s2', 2.0, 2.0, 30.0, '2026-10-27T12:01:01+00:00', 'stand-x'),
    photo('s3', 2.0, 4.0, 0.0, '2026-10-27T12:02:00+00:00', 'stand-y'),
    photo('s4', 2.0, 4.0, 30.0, '2026-10-27T12:02:01+00:00', 'stand-y'),
])])['stands_by_room']['room-a'];
$mixedById = [];
foreach ($mixed as $stand) {
    $mixedById[$stand['stand_id']] = $stand;
}
expect('mixed: stand-x links only to stand-y', array_column($mixedById['stand-x']['neighbours'], 'stand_id'), ['stand-y']);
expect('mixed: stand-y links only to stand-x', array_column($mixedById['stand-y']['neighbours'], 'stand_id'), ['stand-x']);
expect('mixed: wall-photo stands still link to each other', count($mixed[0]['neighbours']), 1);
expect('mixed: no internal keys leak into the output', array_key_exists('captured', $mixed[0]), false);

$photoTourOnly = TourStands::compute([room('room-a', 'Ground', [0.0, 0.0], [], [
    photo('p1', 0.0, 0.0, 0.0, '2026-10-27T10:00:00+00:00'),
    photo('p2', 5.0, 5.0, 90.0, '2026-10-27T10:01:00+00:00'),
    photo('p3', 2.5, 0.0, 180.0, '2026-10-27T10:02:00+00:00'),
])]);
expect('walkthrough: spread-out photos without stand_id stay false', $photoTourOnly['walkthrough'], false);
expect('walkthrough: spread-out photos still listed as stands', count($photoTourOnly['stands_by_room']['room-a']), 3);

echo "\n== Wall photos join the nearest 360 spot ==\n";
expect('merge: NEAREST_STAND_RADIUS_M is larger than STAND_RADIUS_M', TourStands::NEAREST_STAND_RADIUS_M > TourStands::STAND_RADIUS_M, true);

$merged = TourStands::compute([room('room-a', 'Ground', [0.0, 0.0], [], [
    photo('p360a', 2.0, 2.0, 0.0, '2026-10-27T10:00:00+00:00', 'real-stand'),
    photo('p360b', 2.0, 2.0, 90.0, '2026-10-27T10:00:01+00:00', 'real-stand'),
    photo('wall-near', 3.5, 2.0, 90.0, '2026-10-27T10:00:05+00:00'),
])])['stands_by_room']['room-a'];
expect('merge: wall photo within radius joins the real stand', count($merged), 1);
expect('merge: kept the real stand_id', $merged[0]['stand_id'], 'real-stand');
expect('merge: all 3 photos in the merged stand', count($merged[0]['photo_ids']), 3);
expect('merge: wall photo is in the merged photo_ids', in_array('wall-near', $merged[0]['photo_ids'], true), true);

$far = TourStands::compute([room('room-a', 'Ground', [0.0, 0.0], [], [
    photo('p360a', 2.0, 2.0, 0.0, '2026-10-27T10:00:00+00:00', 'real-stand'),
    photo('wall-far', 8.0, 8.0, 90.0, '2026-10-27T10:00:05+00:00'),
])])['stands_by_room']['room-a'];
expect('merge: wall photo outside radius stays on its own', count($far), 2);

$wallOnly = TourStands::compute([room('room-a', 'Ground', [0.0, 0.0], [], [
    photo('wall-1', 1.0, 1.0, 0.0, '2026-10-27T10:00:00+00:00'),
    photo('wall-2', 4.0, 4.0, 90.0, '2026-10-27T10:00:05+00:00'),
])])['stands_by_room']['room-a'];
expect('merge: no captured stand means no merging', count($wallOnly), 2);

$multiple = TourStands::compute([room('room-a', 'Ground', [0.0, 0.0], [], [
    photo('p360a', 2.0, 2.0, 0.0, '2026-10-27T10:00:00+00:00', 'stand-a'),
    photo('p360b', 2.0, 2.0, 90.0, '2026-10-27T10:00:01+00:00', 'stand-a'),
    photo('p360c', 6.0, 2.0, 0.0, '2026-10-27T10:00:02+00:00', 'stand-b'),
    photo('p360d', 6.0, 2.0, 90.0, '2026-10-27T10:00:03+00:00', 'stand-b'),
    photo('wall-a', 3.0, 2.0, 90.0, '2026-10-27T10:00:05+00:00'),
    photo('wall-b', 5.0, 2.0, 90.0, '2026-10-27T10:00:06+00:00'),
])])['stands_by_room']['room-a'];
expect('merge: two captured stands stay separate', count($multiple), 2);
$standA = null;
$standB = null;
foreach ($multiple as $s) {
    if ($s['stand_id'] === 'stand-a') { $standA = $s; }
    if ($s['stand_id'] === 'stand-b') { $standB = $s; }
}
expect('merge: stand-a exists', $standA !== null, true);
expect('merge: stand-b exists', $standB !== null, true);
expect('merge: wall-a joined stand-a', $standA !== null && in_array('wall-a', $standA['photo_ids'], true), true);
expect('merge: wall-b joined stand-b', $standB !== null && in_array('wall-b', $standB['photo_ids'], true), true);

$boundary = TourStands::compute([room('room-a', 'Ground', [0.0, 0.0], [], [
    photo('p360', 2.0, 2.0, 0.0, '2026-10-27T10:00:00+00:00', 'real-stand'),
    photo('wall-at-edge', 2.0 + TourStands::NEAREST_STAND_RADIUS_M, 2.0, 0.0, '2026-10-27T10:00:05+00:00'),
])])['stands_by_room']['room-a'];
expect('merge: exactly at NEAREST_STAND_RADIUS_M merges', count($boundary), 1);

$beyond = TourStands::compute([room('room-a', 'Ground', [0.0, 0.0], [], [
    photo('p360', 2.0, 2.0, 0.0, '2026-10-27T10:00:00+00:00', 'real-stand'),
    photo('wall-past', 2.0 + TourStands::NEAREST_STAND_RADIUS_M + 0.1, 2.0, 0.0, '2026-10-27T10:00:05+00:00'),
])])['stands_by_room']['room-a'];
expect('merge: just past NEAREST_STAND_RADIUS_M stays separate', count($beyond), 2);


if ($failures > 0) {
    fwrite(STDERR, "\n$failures failure(s)\n");
    exit(1);
}
echo "All tour_stands tests passed.\n";
