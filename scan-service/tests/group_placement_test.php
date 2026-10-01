<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';

use VuuroScan\GroupPlacement;

$failures = [];
$checks = 0;

function gp_check(string $label, bool $pass, string $detail = ''): void
{
    global $failures, $checks;
    $checks++;
    if ($pass) {
        echo "  [PASS] $label\n";
    } else {
        $failures[] = "$label - $detail";
        echo "  [FAIL] $label - $detail\n";
    }
}

function gp_approx(float $a, float $b, float $tol = 0.01): bool
{
    return abs($a - $b) <= $tol;
}

function gp_room(string $id, array $outline, array $origin, array $openings = [], array $objects = [], array $walkPath = []): array
{
    return [
        'room_id' => $id,
        'label' => $id,
        'floor_area_m2' => 12.0,
        'perimeter_m' => 14.0,
        'bounding_dimensions_m' => ['width_m' => 4.0, 'length_m' => 3.0],
        'confidence' => 'high',
        'outline_m' => $outline,
        'structure_origin_m' => $origin,
        'openings' => $openings,
        'objects' => $objects,
        'walk_path_m' => $walkPath,
        'floor' => 'Ground floor',
    ];
}

echo "== Rotate 90 degrees around origin ==\n";
$room = gp_room(
    'r1',
    [[0.0, 0.0], [4.0, 0.0], [4.0, 3.0], [0.0, 3.0]],
    [0.0, 0.0],
    [['opening_id' => 'd1', 'category' => 'door', 'position_m' => [4.0, 1.5], 'confidence' => 'high']],
    [['object_id' => 'o1', 'category' => 'table', 'position_m' => [2.0, 1.5], 'dimensions_m' => [1, 1, 1], 'confidence' => 'high', 'yaw_deg' => 0.0]],
    [[1.0, 1.0], [3.0, 1.0]]
);
$rotated = GroupPlacement::transformRoom($room, 90.0, 0.0, 0.0);
$xs = array_column($rotated['outline_m'], 0);
$zs = array_column($rotated['outline_m'], 1);
$width = max($xs) - min($xs);
$length = max($zs) - min($zs);
gp_check('width becomes 3.0 after 90-degree rotation', gp_approx($width, 3.0), (string) $width);
gp_check('length becomes 4.0 after 90-degree rotation', gp_approx($length, 4.0), (string) $length);
gp_check('area unchanged', gp_approx($rotated['floor_area_m2'], 12.0));
gp_check('perimeter unchanged', gp_approx($rotated['perimeter_m'], 14.0));
gp_check('object yaw shifted by 90', gp_approx((float) $rotated['objects'][0]['yaw_deg'], 90.0), (string) $rotated['objects'][0]['yaw_deg']);

echo "\n== Rotation 0 and translation 0 is identity ==\n";
$identity = GroupPlacement::transformRoom($room, 0.0, 0.0, 0.0);
gp_check('outline unchanged', $identity['outline_m'] === $room['outline_m']);
gp_check('origin unchanged', $identity['structure_origin_m'] === $room['structure_origin_m']);
gp_check('opening position unchanged', $identity['openings'][0]['position_m'] === $room['openings'][0]['position_m']);

echo "\n== Translation moves origin ==\n";
$moved = GroupPlacement::transformRoom($room, 0.0, 5.0, 3.0);
gp_check('structure origin shifts by translation', gp_approx((float) $moved['structure_origin_m'][0], 5.0) && gp_approx((float) $moved['structure_origin_m'][1], 3.0));

echo "\n== Refuses groups with splits ==\n";
$withSplits = $room;
$withSplits['room_splits'] = [['room_id' => 'r1', 'mode' => 'split']];
try {
    GroupPlacement::transformRoom($withSplits, 90.0, 0.0, 0.0);
    gp_check('group_has_splits raises', false, 'no exception');
} catch (\InvalidArgumentException $e) {
    gp_check('group_has_splits raises', $e->getMessage() === 'group_has_splits');
}

echo "\n== Refuses groups without structure origin ==\n";
$noOrigin = $room;
unset($noOrigin['structure_origin_m']);
try {
    GroupPlacement::transformRoom($noOrigin, 90.0, 0.0, 0.0);
    gp_check('group_missing_origin raises', false, 'no exception');
} catch (\InvalidArgumentException $e) {
    gp_check('group_missing_origin raises', $e->getMessage() === 'group_missing_origin');
}

echo "\n== Rotation and translation bounds ==\n";
try {
    GroupPlacement::validateRotation(400.0);
    gp_check('rotation above 360 raises', false, 'no exception');
} catch (\InvalidArgumentException) {
    gp_check('rotation above 360 raises', true);
}
try {
    GroupPlacement::validateTranslation(2000.0, 0.0);
    gp_check('translation above 1000 raises', false, 'no exception');
} catch (\InvalidArgumentException) {
    gp_check('translation above 1000 raises', true);
}


echo "\n== Exact positions after 90-degree rotation with non-integer origin ==\n";
$room = gp_room(
    'r1',
    [[0.0, 0.0], [4.0, 0.0], [4.0, 3.0], [0.0, 3.0]],
    [10.0, 20.0],
    [['opening_id' => 'd1', 'category' => 'door', 'position_m' => [4.0, 1.5], 'confidence' => 'high']],
    [['object_id' => 'o1', 'category' => 'table', 'position_m' => [2.0, 1.5], 'dimensions_m' => [1, 1, 1], 'confidence' => 'high', 'yaw_deg' => 45.5]],
    [[1.0, 1.0], [3.0, 1.0]]
);
$rotated = GroupPlacement::transformRoom($room, 90.0, 0.0, 0.0);
gp_check('rotated origin is [-23, 10]', gp_approx((float) $rotated['structure_origin_m'][0], -23.0) && gp_approx((float) $rotated['structure_origin_m'][1], 10.0), json_encode($rotated['structure_origin_m']));
gp_check('rotated outline is [[3,0],[3,4],[0,4],[0,0]]', $rotated['outline_m'] === [[3.0, 0.0], [3.0, 4.0], [0.0, 4.0], [0.0, 0.0]], json_encode($rotated['outline_m']));
gp_check('rotated opening position is [1.5, 4.0]', $rotated['openings'][0]['position_m'] === [1.5, 4.0], json_encode($rotated['openings'][0]['position_m']));
gp_check('rotated object position is [1.5, 2.0]', $rotated['objects'][0]['position_m'] === [1.5, 2.0], json_encode($rotated['objects'][0]['position_m']));
gp_check('object yaw 45.5 + 90 = 135.5 keeps the .5 (fmod, not integer modulo)', gp_approx((float) $rotated['objects'][0]['yaw_deg'], 135.5), (string) $rotated['objects'][0]['yaw_deg']);
gp_check('rotated walk path is [[2,1],[2,3]]', $rotated['walk_path_m'] === [[2.0, 1.0], [2.0, 3.0]], json_encode($rotated['walk_path_m']));

$negative = GroupPlacement::transformRoom($room, -30.0, 0.0, 0.0);
$yawNegative = (float) $negative['objects'][0]['yaw_deg'];
gp_check('negative rotation yaw stays in [0, 360)', $yawNegative >= 0.0 && $yawNegative < 360.0, (string) $yawNegative);
gp_check('45.5 - 30 = 15.5', gp_approx($yawNegative, 15.5), (string) $yawNegative);

echo "\n== Opening stays on a wall after rotation ==\n";
function gp_point_to_segment_distance(array $p, array $a, array $b): float {
    $dx = $b[0] - $a[0]; $dz = $b[1] - $a[1];
    $lenSq = $dx * $dx + $dz * $dz;
    $t = $lenSq < 1e-9 ? 0.0 : max(0.0, min(1.0, (($p[0] - $a[0]) * $dx + ($p[1] - $a[1]) * $dz) / $lenSq));
    return sqrt(($p[0] - $a[0] - $t * $dx) ** 2 + ($p[1] - $a[1] - $t * $dz) ** 2);
}
$openingPos = $rotated['openings'][0]['position_m'];
$minDist = INF;
$n = count($rotated['outline_m']);
for ($i = 0; $i < $n; $i++) {
    $minDist = min($minDist, gp_point_to_segment_distance($openingPos, $rotated['outline_m'][$i], $rotated['outline_m'][($i + 1) % $n]));
}
gp_check('opening stays within 0.01 m of a wall after rotation', $minDist < 0.01, 'distance=' . $minDist);
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
