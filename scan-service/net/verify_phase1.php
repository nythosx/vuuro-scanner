<?php

declare(strict_types=1);

/**
 * Independent verification pass for Phase 1 ("proof of capture").
 *
 * This is the net named in CLAUDE.md hard constraint #6 / PHASES.md, not a
 * regression test suite. It is deliberately built from different
 * assumptions than src/Adapters/RoomPlanSimulatorAdapter.php:
 *
 *   - It does NOT require() or call the adapter. It re-implements its own
 *     polygon-area / perimeter math directly against the raw fixture files,
 *     independently, and compares the result to what the live HTTP API
 *     actually returned.
 *   - It talks to the Scan Service only over HTTP, the same way any real
 *     client (including the eventual Vuuro rental app) would — it never
 *     reaches into the PHP classes or the SQLite file directly.
 *   - A failure here means "the contract lied to a client", which is a
 *     stronger and different claim than "a unit test of the adapter failed".
 *
 * This script exits non-zero on any failure and is meant to gate merges —
 * see CLAUDE.md: "nothing merges past a red verdict, including my own work."
 *
 * Usage: php net/verify_phase1.php [base_url]
 *   base_url defaults to http://127.0.0.1:8089
 */

require_once __DIR__ . '/lib/http_client.php';

$baseUrl = $argv[1] ?? 'http://127.0.0.1:8089';
$failures = [];
$checks = 0;

/**
 * Independently-coded shoelace area. Deliberately written from scratch here
 * rather than shared with the adapter, per CLAUDE.md's requirement that the
 * net "re-derives expected room dimensions/areas from a known fixture
 * independently rather than re-running the same reconstruction path."
 *
 * @param array<int, array{0: float, 1: float}> $xz
 */
function expected_area(array $xz): float
{
    $total = 0.0;
    $n = count($xz);
    for ($i = 0; $i < $n; $i++) {
        $j = ($i + 1) % $n;
        $total += $xz[$i][0] * $xz[$j][1];
        $total -= $xz[$j][0] * $xz[$i][1];
    }
    return abs($total) / 2.0;
}

/** @param array<int, array{0: float, 1: float}> $xz */
function expected_perimeter(array $xz): float
{
    $total = 0.0;
    $n = count($xz);
    for ($i = 0; $i < $n; $i++) {
        $j = ($i + 1) % $n;
        $dx = $xz[$j][0] - $xz[$i][0];
        $dz = $xz[$j][1] - $xz[$i][1];
        $total += hypot($dx, $dz);
    }
    return $total;
}

/**
 * @param array<int, array{0: float, 1: float}> $xz
 * @return array{0: float, 1: float}
 */
function expected_bbox(array $xz): array
{
    $xs = array_map(static fn ($p) => $p[0], $xz);
    $zs = array_map(static fn ($p) => $p[1], $xz);
    return [max($xs) - min($xs), max($zs) - min($zs)];
}

/** @param array<int, array{0: float, 1: float, 2: float}> $corners3d */
function to_xz(array $corners3d): array
{
    return array_map(static fn ($p) => [(float) $p[0], (float) $p[2]], $corners3d);
}

function check(string $label, bool $pass, string $detail = ''): void
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

function approx(float $a, float $b, float $tolerance = 0.01): bool
{
    return abs($a - $b) <= $tolerance;
}

function run_fixture_case(string $baseUrl, string $fixturePath, string $caseLabel): void
{
    echo "== $caseLabel ($fixturePath) ==\n";

    $fixture = json_decode((string) file_get_contents($fixturePath), true, 512, JSON_THROW_ON_ERROR);
    $xz = to_xz($fixture['floors'][0]['polygonCorners']);

    $wantArea = expected_area($xz);
    $wantPerimeter = expected_perimeter($xz);
    [$wantWidth, $wantLength] = expected_bbox($xz);

    [$createStatus, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
        'property_id' => 'prop-net-test',
        'unit_id' => 'unit-net-test',
        'organisation_id' => 'org-net-test',
        'purpose' => 'listing',
        'occupied' => false,
    ]);
    check('session created (HTTP 201)', $createStatus === 201, "got HTTP $createStatus");
    check('session carries all three identity fields', isset($session['property_id'], $session['unit_id'], $session['organisation_id']));

    $sessionId = $session['id'] ?? null;
    $accessToken = $session['access_token'] ?? null;
    if ($sessionId === null || $accessToken === null) {
        check('capture attempted', false, 'no session id/access_token returned, cannot continue this case');
        return;
    }

    [$captureStatus, $floorPlan] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", [
        'raw_capture' => $fixture,
    ], $accessToken);
    check('capture accepted (HTTP 200)', $captureStatus === 200, "got HTTP $captureStatus");

    check('measurement_basis is honest (never certified from an automated adapter)',
        ($floorPlan['measurement_basis'] ?? null) === 'indicative_nen2580_inspired',
        'got: ' . json_encode($floorPlan['measurement_basis'] ?? null));

    $room = $floorPlan['rooms'][0] ?? null;
    check('a room was returned', $room !== null);
    if ($room === null) {
        return;
    }

    check('floor_area_m2 matches independently-derived shoelace area',
        approx((float) $room['floor_area_m2'], $wantArea),
        "API={$room['floor_area_m2']} expected=" . round($wantArea, 4));

    check('perimeter_m matches independently-derived perimeter',
        approx((float) $room['perimeter_m'], $wantPerimeter),
        "API={$room['perimeter_m']} expected=" . round($wantPerimeter, 4));

    check('bounding width_m matches independently-derived bbox',
        approx((float) $room['bounding_dimensions_m']['width_m'], $wantWidth),
        "API={$room['bounding_dimensions_m']['width_m']} expected=" . round($wantWidth, 4));

    check('bounding length_m matches independently-derived bbox',
        approx((float) $room['bounding_dimensions_m']['length_m'], $wantLength),
        "API={$room['bounding_dimensions_m']['length_m']} expected=" . round($wantLength, 4));

    // GET must return the same result the capture call already returned —
    // catches a "write path lies about what read path serves" divergence.
    [$getStatus, $refetched] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId", null, $accessToken);
    check('GET after capture returns HTTP 200', $getStatus === 200, "got HTTP $getStatus");
    check('GET result matches captured result exactly', $refetched === $floorPlan, 'refetched floor plan differs from capture response');

    echo "\n";
}

// Regression case: the straightforward rectangular room this adapter was
// built and tested against first.
run_fixture_case($baseUrl, __DIR__ . '/../fixtures/roomplan_captured_room_single_room.json', 'Regression: single rectangular room');

// Adjacent case: a non-rectangular, concave (L-shaped) room. A bounding-box
// or width*length shortcut would pass the rectangular case above and still
// silently return the wrong area/perimeter here. This is exactly the
// "adjacent case beside the one being fixed" failure shape CLAUDE.md calls
// out — constructed deliberately, not discovered after a bug report.
run_fixture_case($baseUrl, __DIR__ . '/../fixtures/roomplan_captured_room_lshaped_adversarial.json', 'Adversarial: L-shaped concave room');

// Identity-native capture, checked negatively: creating a session missing
// any identity field must be rejected, not silently defaulted (hard
// constraint #1 — "an orphan capture is a bug").
foreach (['property_id', 'unit_id', 'organisation_id'] as $missingField) {
    $payload = [
        'property_id' => 'prop-x',
        'unit_id' => 'unit-x',
        'organisation_id' => 'org-x',
        'purpose' => 'listing',
        'occupied' => false,
    ];
    unset($payload[$missingField]);
    [$status, ] = net_http_json('POST', "$baseUrl/scan-sessions", $payload);
    check("session creation rejected when $missingField is missing", $status === 422, "got HTTP $status");
}

echo "\n" . count($failures) . " failure(s) out of $checks check(s).\n";

if ($failures !== []) {
    fwrite(STDERR, "\nNET VERDICT: RED\n");
    foreach ($failures as $f) {
        fwrite(STDERR, " - $f\n");
    }
    exit(1);
}

echo "\nNET VERDICT: GREEN\n";
exit(0);
