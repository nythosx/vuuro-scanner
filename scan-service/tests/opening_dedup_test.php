<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';

use VuuroScan\Export\OpeningDedup;

$failures = [];
$checks = 0;

function od_check(string $label, bool $pass, string $detail = ''): void
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

$pose = static fn (float $x, float $z) => ['originX' => $x, 'originZ' => $z, 'rotationRad' => 0.0];
$rooms = [
    ['openings' => [
        ['opening_id' => 'a-door', 'category' => 'door', 'position_m' => [2.0, 4.0]],
        ['opening_id' => 'a-window', 'category' => 'window', 'position_m' => [1.0, 0.0]],
    ]],
    ['openings' => [
        ['opening_id' => 'b-door', 'category' => 'door', 'position_m' => [2.1, 0.05]],
        ['opening_id' => 'b-window', 'category' => 'window', 'position_m' => [2.0, 0.05]],
        ['opening_id' => 'b-door-2', 'category' => 'door', 'position_m' => [3.5, 0.05]],
    ]],
];
$poses = [$pose(0.0, 0.0), $pose(0.0, 3.95)];

echo "== Doors and windows shared by two rooms ==\n";
$filtered = OpeningDedup::filter($rooms, $poses);
$ids = array_merge(...array_map(static fn (array $room) => array_column($room['openings'], 'opening_id'), $filtered));
od_check('the door both rooms reported on their shared wall is drawn once', !in_array('b-door', $ids, true) && in_array('a-door', $ids, true), json_encode($ids));
od_check('a window next to that door is kept, it is a different kind of opening', in_array('b-window', $ids, true), json_encode($ids));
od_check('a second door further along the wall is kept', in_array('b-door-2', $ids, true), json_encode($ids));
od_check('openings far apart in the first room are untouched', in_array('a-window', $ids, true), json_encode($ids));
od_check('a room with no openings key still works', OpeningDedup::filter([['outline_m' => []]], [$pose(0.0, 0.0)])[0]['openings'] === []);

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
