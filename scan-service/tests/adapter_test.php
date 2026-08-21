<?php

declare(strict_types=1);

/**
 * Fast in-process unit tests for RoomPlanSimulatorAdapter. These exercise
 * the adapter directly and are meant for quick dev-loop feedback — they are
 * NOT the independent net (see net/verify_capture_geometry.php), because they share
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
t_check('outline_m has 4 points for a 4-corner rectangle', count($result['rooms'][0]['outline_m']) === 4);
t_check('outline_m is room-local: min x is 0', min(array_column($result['rooms'][0]['outline_m'], 0)) === 0.0);
t_check('outline_m is room-local: min z is 0', min(array_column($result['rooms'][0]['outline_m'], 1)) === 0.0);
t_check('outline_m bounding box matches bounding_dimensions_m width',
    t_approx(max(array_column($result['rooms'][0]['outline_m'], 0)), $result['rooms'][0]['bounding_dimensions_m']['width_m']));

// Hand-computed: 7 surfaces (floor, 4 walls, 1 door, 1 window) — 6 high (100)
// + 1 medium wall (60) = 660 / 7 = 94.28 -> round 94.
t_check('coverage score for the mostly-high-confidence fixture is 94', $result['rooms'][0]['coverage']['score'] === 94);
t_check('coverage.usable is true at 94', $result['rooms'][0]['coverage']['usable'] === true);
t_check('coverage.message is null when usable', $result['rooms'][0]['coverage']['message'] === null);
t_check('coverage.confidence_counts has 6 high, 1 medium, 0 low',
    $result['rooms'][0]['coverage']['confidence_counts'] === ['high' => 6, 'medium' => 1, 'low' => 0]);
echo "\n";

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

// Deliberately adversarial: the floor surface itself is high confidence (so
// area/perimeter are fine, and a coverage score that only read
// floor.confidence would report this as fully usable), but most walls/
// doors/windows are low/medium. A landlord relying on this score to decide
// whether to walk away needs the honest aggregate, not the easy field.
echo "== Adjacent case: coverage reflects wall/door/window confidence, not just the floor's ==\n";
$lowConfFixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_low_confidence_adversarial.json'), true, 512, JSON_THROW_ON_ERROR);
$lowConfResult = $adapter->adapt($lowConfFixture, $identity);
$lowConfCoverage = $lowConfResult['rooms'][0]['coverage'];

// Hand-computed: floor(100) + wall(20)+wall(20)+wall(60)+wall(20) + door(20) + window(60)
// = 300 / 7 = 42.85 -> round 43.
t_check('coverage score for the low-confidence fixture is 43, not the floor-only 100', $lowConfCoverage['score'] === 43);
t_check('coverage.usable is false below the 70 threshold', $lowConfCoverage['usable'] === false);
t_check('coverage.message is a non-empty rescan prompt when not usable', is_string($lowConfCoverage['message']) && $lowConfCoverage['message'] !== '');
t_check('coverage.confidence_counts has 1 high (the floor), not 6', $lowConfCoverage['confidence_counts']['high'] === 1);
echo "\n";

// Simulates two sequential single-room RoomPlan captures in the same
// session, stitched into one multi-room unit package. The Scan Service passes
// roomCount() as roomIndexOffset for the second call — exercised directly
// here since that offset threading is the adapter's responsibility.
echo "== Multi-room: room numbering continues across capture calls ==\n";
$secondCallResult = $adapter->adapt($fixture, $identity, 1);
t_check('second call with offset 1 labels its room "Room 2"', $secondCallResult['rooms'][0]['label'] === 'Room 2');
t_check('first call (offset 0) labeled its room "Room 1"', $result['rooms'][0]['label'] === 'Room 1');
t_check('room_id differs between offset 0 and offset 1 calls even for the same fixture',
    $result['rooms'][0]['room_id'] !== $secondCallResult['rooms'][0]['room_id']);
echo "\n";

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

// --- Security: malformed/oversized input is rejected cleanly, not left to
// crash downstream (found via manual review, confirmed exploitable against
// the live server before this validation existed — see git history / the
// security-review findings). Each of these must throw InvalidArgumentException
// (-> a clean 422 in public/index.php), never propagate INF/NaN into
// floor_area_m2 or an oversized array into the exports.
echo "== Security: reject non-finite and oversized capture geometry ==\n";

try {
    $adapter->adapt(['floors' => [['identifier' => 'f', 'polygonCorners' => [[0, 0, 0], [1e400, 0, 0], [1e400, 0, 1], [0, 0, 1]]]]], $identity);
    t_check('adapt() rejects a non-finite (INF) coordinate', false, 'no exception was thrown -- this is the exact payload that previously crashed the live server');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects a non-finite (INF) coordinate', true);
}

try {
    $adapter->adapt(['floors' => [['identifier' => 'f', 'polygonCorners' => [[0, 0, 0], [50000, 0, 0], [50000, 0, 1], [0, 0, 1]]]]], $identity);
    t_check('adapt() rejects a coordinate far beyond any real room (50000m)', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects a coordinate far beyond any real room (50000m)', true);
}

try {
    $tooManyFloors = array_fill(0, 51, ['identifier' => 'f', 'polygonCorners' => [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]]]);
    $adapter->adapt(['floors' => $tooManyFloors], $identity);
    t_check('adapt() rejects more than 50 floors in one capture call', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects more than 50 floors in one capture call', true);
}

try {
    $tooManyCorners = array_fill(0, 1001, [0, 0, 0]);
    $adapter->adapt(['floors' => [['identifier' => 'f', 'polygonCorners' => $tooManyCorners]]], $identity);
    t_check('adapt() rejects a floor with more than 1000 polygonCorners', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects a floor with more than 1000 polygonCorners', true);
}

// Capture-surface scan finding: is_array() is true for both a JSON array
// ([...], decodes to sequential int keys) and a JSON object ({...}, decodes
// to string keys) -- the earlier is_array(floors) gate let a
// {"floors": {"myFloor": {...}}} payload straight through, and adapt()'s
// room-building loop does `$roomIndexOffset + $index` on that key with no
// type check. Confirmed live before this fix: that payload crashed with an
// uncaught TypeError ("Unsupported operand types: int + string"), not the
// clean InvalidArgumentException this class's own docblock promises --
// and a TypeError isn't caught by the capture route's
// catch(\InvalidArgumentException), so it also skipped the
// idempotency-claim release fix, same as any other uncaught exception on
// that path.
try {
    $floorsAsObject = json_decode('{"floors":{"myFloor":{"identifier":"f","polygonCorners":[[0,0,0],[1,0,0],[1,0,1],[0,0,1]]}}}', true);
    $adapter->adapt($floorsAsObject, $identity);
    t_check('adapt() rejects floors[] sent as a JSON object instead of an array, not a crash', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects floors[] sent as a JSON object instead of an array, not a crash', true);
} catch (\Throwable $e) {
    t_check('adapt() rejects floors[] sent as a JSON object instead of an array, not a crash', false, 'threw ' . get_class($e) . ' instead of InvalidArgumentException: ' . $e->getMessage());
}

try {
    $tooManyWalls = array_fill(0, 501, ['identifier' => 'w', 'confidence' => 'high']);
    $adapter->adapt(['floors' => $fixture['floors'], 'walls' => $tooManyWalls], $identity);
    t_check('adapt() rejects more than 500 walls in one capture call', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects more than 500 walls in one capture call', true);
}

// A large-but-in-bounds room must still work — the fix rejects abuse, not
// legitimate (if generous) real-world geometry.
$largeButValid = $adapter->adapt(['floors' => [['identifier' => 'f', 'polygonCorners' => [[0, 0, 0], [20, 0, 0], [20, 0, 15], [0, 0, 15]]]]], $identity);
t_check('a large but plausible room (20m x 15m) is still accepted', $largeButValid['rooms'][0]['floor_area_m2'] === 300.0);
echo "\n";

// Capture-surface scan finding: a non-numeric polygonCorners coordinate
// (string/bool/array) fell straight through validateRawCapture()'s
// is_int()/is_float() check via a bare `continue`, then got silently
// coerced by adapt()'s `(float) ($p[0] ?? 0)` cast -- a string became 0.0,
// a bool became 0.0/1.0, an array became 0.0/1.0 -- producing a wrong-but-
// plausible room outline/area with zero error anywhere. Same silent-
// corruption shape as the capture_provider/identifier bugs, just on a
// coordinate. Confirmed live before the fix: a corner of
// ["not_a_number", 0, 0] adapted into a clean 200 with floor_area_m2: 9,
// no error surfaced. `null` stays accepted (adapt()'s own `?? 0` treats a
// genuinely-absent dimension as 0, same as a corner shorter than 3 values)
// -- only a present-but-wrong-typed value is rejected.
echo "== Adjacent case: a non-numeric polygonCorners coordinate must not silently coerce to 0 ==\n";
foreach (['a string' => 'not_a_number', 'a bool' => true, 'a nested array' => [1, 2]] as $label => $badCoordinate) {
    try {
        $adapter->adapt(['floors' => [['identifier' => 'f', 'polygonCorners' => [[$badCoordinate, 0, 0], [3, 0, 0], [3, 0, 3], [0, 0, 3]]]]], $identity);
        t_check("adapt() rejects a polygonCorners coordinate that is $label, not silently coerced", false, 'no exception was thrown');
    } catch (\InvalidArgumentException) {
        t_check("adapt() rejects a polygonCorners coordinate that is $label, not silently coerced", true);
    }
}
$nullCoordinate = $adapter->adapt(['floors' => [['identifier' => 'f', 'polygonCorners' => [[null, 0, 0], [3, 0, 0], [3, 0, 3], [0, 0, 3]]]]], $identity);
t_check('a genuinely-absent (null) coordinate is still accepted, falling back to 0 as before', $nullCoordinate['rooms'][0]['outline_m'][0] === [0.0, 0.0]);
echo "\n";

// --- Adjacent case: honest measurement means rejecting degenerate geometry,
// not just oversized/non-finite geometry -------------------------------
// Found by deliberately probing past the security checks above for the case
// they don't cover: collinear or duplicate polygonCorners produce a
// perfectly finite, in-bounds outline whose shoelace area is ~0. Before
// MIN_POLYGON_AREA_M2 existed, this adapted into a real "Room 1" with
// floor_area_m2: 0, confidence: high, coverage.usable: true — a landlord-
// facing lie of omission, not a crash. Hard constraint #2 (honest
// measurement language) is about exactly this, not just the certified-vs-
// indicative label.
echo "== Adjacent case: degenerate (collinear-corner) outline is rejected, not silently zero-area ==\n";
$degenerate = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_degenerate_adversarial.json'), true, 512, JSON_THROW_ON_ERROR);
try {
    $adapter->adapt($degenerate, $identity);
    t_check('adapt() rejects a collinear-corner (0 m2) outline', false, 'no exception was thrown -- this used to silently produce a "usable" 0 m2 room');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects a collinear-corner (0 m2) outline', true);
}

// Same failure mode from a different shape: a self-intersecting ("bowtie")
// quad whose shoelace terms happen to cancel to ~0 must be caught by the
// same area-floor check, not just the straight-line case above.
try {
    $bowtie = ['floors' => [['identifier' => 'f', 'confidence' => 'high', 'polygonCorners' => [[0, 0, 0], [4, 0, 4], [4, 0, 0], [0, 0, 4]]]]];
    $adapter->adapt($bowtie, $identity);
    t_check('adapt() rejects a self-intersecting outline whose area cancels to ~0', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects a self-intersecting outline whose area cancels to ~0', true);
}

// A small-but-real room (a closet, e.g. 0.8m x 0.8m = 0.64 m2) must NOT be
// caught by the same floor — this rejects degenerate junk, not small rooms.
$smallButReal = $adapter->adapt(['floors' => [['identifier' => 'f', 'confidence' => 'high', 'polygonCorners' => [[0, 0, 0], [0.8, 0, 0], [0.8, 0, 0.8], [0, 0, 0.8]]]]], $identity);
t_check('a small but real room (0.64 m2 closet) is still accepted, not rejected as degenerate', t_approx($smallButReal['rooms'][0]['floor_area_m2'], 0.64));
echo "\n";

// Full-functionality scan finding: 'confidence' on any raw_capture surface
// is entirely client-controlled JSON, but mapConfidence() used to take a
// typed `?string $raw` parameter — a non-string, non-null value (a number,
// array, or bool) threw an uncaught TypeError under this codebase's own
// declare(strict_types=1), confirmed live as a raw HTTP 500 before this fix.
// The safe answer is the same one this codebase already gives an
// unrecognized STRING value (mapConfidence's own `default => 'low'` arm):
// treat a value it can't make sense of as 'low' confidence, not as a crash.
echo "== Adjacent case: a non-string 'confidence' on any surface must not crash ==\n";
$nonStringConfidence = $adapter->adapt(['floors' => [['identifier' => 'f', 'confidence' => 12345, 'polygonCorners' => [[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]]]]], $identity);
t_check("a numeric 'confidence' (12345) does not crash and maps to 'low', same as an unrecognized string would", $nonStringConfidence['rooms'][0]['confidence'] === 'low');

$arrayConfidence = $adapter->adapt(['floors' => [['identifier' => 'f', 'confidence' => ['nested', 'array'], 'polygonCorners' => [[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]]]]], $identity);
t_check("an array 'confidence' does not crash and maps to 'low'", $arrayConfidence['rooms'][0]['confidence'] === 'low');

// Full-functionality scan finding, one level deeper than the "fewer than 3
// polygonCorners" check above: polygonCorners is entirely client-controlled
// JSON, and nothing validated that each ENTRY is itself an array — only that
// the outer array had >=3 entries. A malformed entry (three scalars instead
// of three [x,y,z] points) used to reach a typed `array $p` closure
// parameter and throw an uncaught TypeError, confirmed live as a raw
// HTTP 500 before this fix.
echo "== Adjacent case: a polygonCorners entry that isn't itself an array must not crash ==\n";
try {
    $adapter->adapt(['floors' => [['identifier' => 'f', 'polygonCorners' => [1, 2, 3]]]], $identity);
    t_check('adapt() rejects scalar polygonCorners entries with a clean exception, not a crash', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check('adapt() rejects scalar polygonCorners entries with a clean exception, not a crash', true);
} catch (\TypeError $e) {
    t_check('adapt() rejects scalar polygonCorners entries with a clean exception, not a crash', false, 'threw TypeError instead: ' . $e->getMessage());
}

// Full-functionality scan finding: 'walls'/'doors'/'windows'/'openings' are
// client-controlled JSON, and computeCoverage()'s array_merge() (unlike a
// typed function parameter) throws an uncaught TypeError — not a warning —
// when given a non-array argument. A capture with an otherwise-valid floor
// but a non-array 'walls' (e.g. a plain string) used to crash to a raw
// HTTP 500. The fix treats a non-array group the same as an omitted one
// (contributes zero surfaces), matching how validateRawCapture() already
// treats these same four groups for its own MAX_SURFACES_PER_GROUP check.
echo "== Adjacent case: a non-array walls/doors/windows/openings group must not crash ==\n";
$nonArrayWalls = $adapter->adapt(['floors' => [['identifier' => 'f', 'confidence' => 'high', 'polygonCorners' => [[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]]]], 'walls' => 'not-an-array'], $identity);
t_check("a non-array 'walls' group does not crash and is treated as contributing zero surfaces", $nonArrayWalls['rooms'][0]['coverage']['confidence_counts'] === ['high' => 1, 'medium' => 0, 'low' => 0]);

// ACL/adapter-surface scan finding: 'identifier' is optional but
// client-suppliable, and was cast with `(string) (...)` into room_id with no
// type check first — same silent-corruption bug class as 'capture_provider'
// fixed earlier (PHP's (string) cast on an array doesn't throw, it silently
// produces the literal string "Array"). Confirmed live before this fix: a
// capture with a non-string identifier returned a clean 200 with room_id
// "room-01-Array" — no error anywhere, and room_id feeds every later
// photo/note room_id match. Now rejected instead of silently coerced.
echo "== Adjacent case: a non-string 'identifier' must not silently corrupt room_id ==\n";
try {
    $adapter->adapt(['floors' => [['identifier' => ['nested', 'array'], 'polygonCorners' => [[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]]]]], $identity);
    t_check("adapt() rejects a non-string 'identifier' with a clean exception, not silent corruption", false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    t_check("adapt() rejects a non-string 'identifier' with a clean exception, not silent corruption", true);
}
$omittedIdentifier = $adapter->adapt(['floors' => [['polygonCorners' => [[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]]]]], $identity);
t_check("omitting 'identifier' entirely still works (falls back to 'floor-N')", $omittedIdentifier['rooms'][0]['room_id'] === 'room-01-floor-0');
$stringIdentifier = $adapter->adapt(['floors' => [['identifier' => 'my-floor', 'polygonCorners' => [[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]]]]], $identity);
t_check("a real string 'identifier' still works normally", $stringIdentifier['rooms'][0]['room_id'] === 'room-01-my-floor');

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
