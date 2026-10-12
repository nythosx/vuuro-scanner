<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';

use VuuroScan\Export\FloorGroups;

$failures = [];
$checks = 0;

function fg_check(string $label, bool $pass, string $detail = ''): void
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

$roomA = ['room_id' => 'a', 'label' => 'A', 'capture_group_id' => 'group-A', 'structure_origin_m' => [0.0, 0.0], 'floor' => 'Ground'];
$roomB = ['room_id' => 'b', 'label' => 'B', 'capture_group_id' => 'group-B', 'structure_origin_m' => [10.0, 0.0], 'floor' => 'Ground'];

echo "== Two unjoined blocks on one floor are two sections ==\n";
fg_check('unjoined: 2 groups', count(FloorGroups::split([$roomA, $roomB])) === 2);

$roomB['joined_to_group_id'] = 'group-A';

echo "\n== After B joins A, one section ==\n";
fg_check('joined: 1 group', count(FloorGroups::split([$roomA, $roomB])) === 1);

echo "\n" . count($failures) . " failure(s) out of $checks check(s).\n";
if ($failures !== []) {
    fwrite(STDERR, "\nTEST VERDICT: RED\n");
    exit(1);
}
echo "\nTEST VERDICT: GREEN\n";
exit(0);
