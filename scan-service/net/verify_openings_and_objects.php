<?php

declare(strict_types=1);

/**
 * Independent verification for LIDAR-10 (doors/windows/height/objects):
 * re-derives expected openings/height/volume/objects counts and values from
 * the raw fixture JSON, from scratch (never imports RoomPlanSimulatorAdapter
 * or reuses any of its helpers), and checks the live HTTP API against them.
 * Talks to the Scan Service only over HTTP — same shape as
 * verify_capture_geometry.php and verify_coverage.php.
 *
 * This is the card's own required check: "A check that would fail if a door
 * was present in capture and missing in the contract." A door/window/opening
 * with no polygonCorners (no position reported) is correctly dropped by the
 * adapter, not a contract gap — this script counts only positioned items,
 * matching what mapOpenings()/mapObjects() are documented to do.
 *
 * Usage: php net/verify_openings_and_objects.php [base_url]
 *   base_url defaults to http://127.0.0.1:8089
 */

require_once __DIR__ . '/lib/http_client.php';

$baseUrl = $argv[1] ?? 'http://127.0.0.1:8089';
$failures = [];
$checks = 0;

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

/** Independently counts, per category, every door/window/opening in the raw
 * fixture that actually carries a positioned polygonCorners — the only ones
 * the contract is expected to carry forward. */
function expected_opening_counts(array $fixture): array
{
    $counts = ['door' => 0, 'window' => 0, 'opening' => 0];
    foreach (['doors' => 'door', 'windows' => 'window', 'openings' => 'opening'] as $group => $category) {
        foreach ($fixture[$group] ?? [] as $item) {
            if (is_array($item['polygonCorners'] ?? null) && !empty($item['polygonCorners'])) {
                $counts[$category]++;
            }
        }
    }
    return $counts;
}

/** Independently recomputes the tallest wall dimensions[1] in the raw fixture. */
function expected_height(array $fixture): ?float
{
    $heights = [];
    foreach ($fixture['walls'] ?? [] as $wall) {
        $h = $wall['dimensions'][1] ?? null;
        if (is_numeric($h) && (float) $h > 0) {
            $heights[] = (float) $h;
        }
    }
    return empty($heights) ? null : max($heights);
}

function run_fixture_case(string $baseUrl, string $fixturePath, string $caseLabel): void
{
    echo "== $caseLabel ($fixturePath) ==\n";

    $fixture = json_decode((string) file_get_contents($fixturePath), true, 512, JSON_THROW_ON_ERROR);
    $wantOpeningCounts = expected_opening_counts($fixture);
    $wantOpeningTotal = array_sum($wantOpeningCounts);
    $wantObjectCount = count($fixture['objects'] ?? []);
    $wantHeight = expected_height($fixture);

    [$createStatus, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
        'property_id' => 'prop-net-openings-test',
        'unit_id' => 'unit-net-openings-test',
        'organisation_id' => 'org-net-openings-test',
        'purpose' => 'listing',
        'occupied' => false,
    ]);
    check('session created (HTTP 201)', $createStatus === 201, "got HTTP $createStatus");

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

    $room = $floorPlan['rooms'][0] ?? null;
    check('a room was returned', $room !== null);
    if ($room === null) {
        return;
    }

    // The card's own required check: every positioned door/window in the
    // capture has a matching openings[] entry — none silently dropped.
    check('openings[] total count matches the fixture\'s positioned doors/windows/openings',
        count($room['openings'] ?? []) === $wantOpeningTotal,
        'API=' . count($room['openings'] ?? []) . " expected=$wantOpeningTotal");

    $gotCounts = ['door' => 0, 'window' => 0, 'opening' => 0];
    foreach ($room['openings'] ?? [] as $opening) {
        $category = $opening['category'] ?? '?';
        if (isset($gotCounts[$category])) {
            $gotCounts[$category]++;
        }
        check("openings[] entry '{$opening['opening_id']}' has a non-null position_m",
            isset($opening['position_m']) && is_array($opening['position_m']) && count($opening['position_m']) === 2,
            'position_m: ' . json_encode($opening['position_m'] ?? null));
    }
    check('openings[] category breakdown matches the fixture',
        $gotCounts === $wantOpeningCounts,
        'API=' . json_encode($gotCounts) . ' expected=' . json_encode($wantOpeningCounts));

    // height_m / volume_m3_indicative: null must stay null, never a
    // fabricated 0, and a real value must match the independently
    // recomputed tallest wall height.
    if ($wantHeight === null) {
        // `?? 'missing'` would wrongly treat a present-but-null value the
        // same as a missing key — array_key_exists() is required here.
        check('height_m is null when the fixture has no usable wall height',
            array_key_exists('height_m', $room) && $room['height_m'] === null,
            'API=' . json_encode($room['height_m'] ?? 'key missing'));
        check('volume_m3_indicative is null when height_m is null',
            array_key_exists('volume_m3_indicative', $room) && $room['volume_m3_indicative'] === null,
            'API=' . json_encode($room['volume_m3_indicative'] ?? 'key missing'));
    } else {
        check('height_m matches the independently-recomputed tallest wall dimensions[1]',
            isset($room['height_m']) && approx((float) $room['height_m'], $wantHeight),
            'API=' . ($room['height_m'] ?? 'null') . " expected=$wantHeight");
        $wantVolume = round(((float) $room['floor_area_m2']) * $wantHeight, 2);
        check('volume_m3_indicative matches floor_area_m2 * height_m',
            isset($room['volume_m3_indicative']) && approx((float) $room['volume_m3_indicative'], $wantVolume),
            'API=' . ($room['volume_m3_indicative'] ?? 'null') . " expected=$wantVolume");
    }

    check('objects[] count matches the fixture (empty only when the fixture has none)',
        count($room['objects'] ?? []) === $wantObjectCount,
        'API=' . count($room['objects'] ?? []) . " expected=$wantObjectCount");

    $wantCategories = array_column($fixture['objects'] ?? [], 'category');
    $gotCategories = array_column($room['objects'] ?? [], 'category');
    check('objects[] categories round-trip in order, never invented',
        $gotCategories === $wantCategories,
        'API=' . json_encode($gotCategories) . ' expected=' . json_encode($wantCategories));

    // GET must return the same result the capture call already returned —
    // catches a "write path lies about what read path serves" divergence,
    // same check verify_capture_geometry.php already runs for area/perimeter.
    [$getStatus, $refetched] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId", null, $accessToken);
    check('GET after capture returns HTTP 200', $getStatus === 200, "got HTTP $getStatus");
    check('GET result matches captured result exactly (openings/height/objects included)', $refetched === $floorPlan);

    echo "\n";
}

run_fixture_case($baseUrl, __DIR__ . '/../fixtures/roomplan_captured_room_single_room.json', 'Regression: single room with one door, one window, one object');
run_fixture_case($baseUrl, __DIR__ . '/../fixtures/roomplan_captured_room_openings_and_objects.json', 'Adversarial: multiple doors/windows/objects, no walls (height must be null)');

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
