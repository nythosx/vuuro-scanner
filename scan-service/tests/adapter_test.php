<?php

declare(strict_types=1);

/**
 * Fast in-process unit tests for RoomPlanSimulatorAdapter. These exercise
 * the adapter directly and are meant for quick dev-loop feedback — they are
 * NOT the independent net (see net/verify_phase1.php), because they share
 * the adapter's own assumptions by construction. Both must be run before a
 * merge; neither substitutes for the other.
 *
 * Usage: php tests/adapter_test.php
 */

require __DIR__ . '/../src/autoload.php';

use VuuroScan\Adapters\RoomPlanSimulatorAdapter;

$failures = [];
$checks = 0;

function t_check(string $label, bool $pass, string $detail = ''): void
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

function t_approx(float $a, float $b, float $tol = 0.01): bool
{
    return abs($a - $b) <= $tol;
}

$identity = [
    'scan_session_id' => 'sess-test-1',
    'property_id' => 'prop-test-1',
    'unit_id' => 'unit-test-1',
    'organisation_id' => 'org-test-1',
    'purpose' => 'listing',
];

$adapter = new RoomPlanSimulatorAdapter();

// --- Regression: rectangular room fixture -----------------------------
echo "== Regression: rectangular room ==\n";
$fixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);
$result = $adapter->adapt($fixture, $identity);

t_check('scan_session_id bound', $result['scan_session_id'] === 'sess-test-1');
t_check('property_id bound', $result['property_id'] === 'prop-test-1');
t_check('unit_id bound', $result['unit_id'] === 'unit-test-1');
t_check('organisation_id bound', $result['organisation_id'] === 'org-test-1');
t_check('measurement_basis is indicative, never certified', $result['measurement_basis'] === 'indicative_nen2580_inspired');
t_check('exactly one room for one floor', count($result['rooms']) === 1);
t_check('area is 4.20 x 3.10 = 13.02 m2', t_approx($result['rooms'][0]['floor_area_m2'], 13.02));
t_check('perimeter is 2*(4.20+3.10) = 14.60 m', t_approx($result['rooms'][0]['perimeter_m'], 14.60));
t_check('photos present and empty (Phase 1)', $result['photos'] === []);
t_check('notes present and empty (Phase 1)', $result['notes'] === []);
echo "\n";

// --- Adjacent case: adapter must not assume rectangles -----------------
// Deliberately adversarial: a bounding-box-only implementation would still
// pass every check above. This is the check that catches it.
echo "== Adjacent case: L-shaped concave room ==\n";
$lshaped = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_lshaped_adversarial.json'), true, 512, JSON_THROW_ON_ERROR);
$lResult = $adapter->adapt($lshaped, $identity);
$lRoom = $lResult['rooms'][0];

// Independently hand-computed: 4x3 rect (12.0) minus a 1.5x1.2 notch (1.8) = 10.2 m2.
t_check('L-shaped area is 10.20 m2, not the 12.0 m2 bounding-box area', t_approx($lRoom['floor_area_m2'], 10.20));
t_check('L-shaped area is NOT the naive bounding-box area (12.0)', !t_approx($lRoom['floor_area_m2'], 12.00, 0.001));
t_check('L-shaped perimeter is 14.0 m', t_approx($lRoom['perimeter_m'], 14.00));
t_check('L-shaped bounding width is 4.0 m (bbox, not perimeter-derived)', t_approx($lRoom['bounding_dimensions_m']['width_m'], 4.00));
t_check('L-shaped bounding length is 3.0 m', t_approx($lRoom['bounding_dimensions_m']['length_m'], 3.00));
echo "\n";

// --- Error handling: honest failure, not silent wrong output -----------
echo "== Error handling ==\n";
try {
    $adapter->adapt(['floors' => []], $identity);
    t_check('adapt() rejects a capture with no floors', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects a capture with no floors', true);
}

try {
    $adapter->adapt(['floors' => [['identifier' => 'f', 'polygonCorners' => [[0, 0, 0], [1, 0, 0]]]]], $identity);
    t_check('adapt() rejects a floor with fewer than 3 corners', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects a floor with fewer than 3 corners', true);
}
echo "\n";

echo count($failures) . " failure(s) out of $checks check(s).\n";
if ($failures !== []) {
    fwrite(STDERR, "\nTEST VERDICT: RED\n");
    foreach ($failures as $f) {
        fwrite(STDERR, " - $f\n");
    }
    exit(1);
}
echo "\nTEST VERDICT: GREEN\n";
exit(0);
