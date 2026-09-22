<?php

declare(strict_types=1);

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




    if ($wantHeight === null) {


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

    [$getStatus, $refetched] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId", null, $accessToken);
    check('GET after capture returns HTTP 200', $getStatus === 200, "got HTTP $getStatus");
    check('GET result matches captured result exactly (openings/height/objects included)', $refetched === $floorPlan);

    echo "\n";
}

run_fixture_case($baseUrl, __DIR__ . '/../fixtures/roomplan_captured_room_single_room.json', 'Regression: single room with one door, one window, one object');
run_fixture_case($baseUrl, __DIR__ . '/../fixtures/roomplan_captured_room_openings_and_objects.json', 'Adversarial: multiple doors/windows/objects, no walls (height must be null)');

echo "== Room-type guess (live-classified on-device, passed through by the adapter) ==\n";
$roomTypeFixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);

[, $roomTypeSession] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-room-type',
    'unit_id' => 'unit-net-room-type',
    'organisation_id' => 'org-net-room-type',
    'purpose' => 'listing',
    'occupied' => false,
]);
$roomTypeSessionId = $roomTypeSession['id'] ?? null;
$roomTypeToken = $roomTypeSession['access_token'] ?? null;
check('session created for the room-type test', $roomTypeSessionId !== null && $roomTypeToken !== null);

if ($roomTypeSessionId !== null && $roomTypeToken !== null) {
    [, $withGuess] = net_http_json('POST', "$baseUrl/scan-sessions/$roomTypeSessionId/capture", ['raw_capture' => $roomTypeFixture], $roomTypeToken);
    check('room_type round-trips the fixture\'s guess/guess_source/confirmed exactly',
        ($withGuess['rooms'][0]['room_type'] ?? null) === $roomTypeFixture['room_type']);

    $noGuessFixture = $roomTypeFixture;
    unset($noGuessFixture['room_type']);
    [, $noGuessSession] = net_http_json('POST', "$baseUrl/scan-sessions", [
        'property_id' => 'prop-net-room-type-none', 'unit_id' => 'u', 'organisation_id' => 'o', 'purpose' => 'listing', 'occupied' => false,
    ]);
    [, $noGuess] = net_http_json('POST', "$baseUrl/scan-sessions/{$noGuessSession['id']}/capture", ['raw_capture' => $noGuessFixture], $noGuessSession['access_token']);
    check('room_type is null when the capture reported none',
        array_key_exists('room_type', $noGuess['rooms'][0] ?? []) && $noGuess['rooms'][0]['room_type'] === null);

    $invalidFixture = $roomTypeFixture;
    $invalidFixture['room_type'] = ['guess' => 'not_a_real_room_type', 'guess_source' => 'roomplan_section', 'confirmed' => null];
    [, $invalidSession] = net_http_json('POST', "$baseUrl/scan-sessions", [
        'property_id' => 'prop-net-room-type-invalid', 'unit_id' => 'u', 'organisation_id' => 'o', 'purpose' => 'listing', 'occupied' => false,
    ]);
    [, $invalidResult] = net_http_json('POST', "$baseUrl/scan-sessions/{$invalidSession['id']}/capture", ['raw_capture' => $invalidFixture], $invalidSession['access_token']);
    check('an unrecognized guess value is dropped to null, never stored as-is',
        array_key_exists('room_type', $invalidResult['rooms'][0] ?? []) && $invalidResult['rooms'][0]['room_type'] === null);
}
echo "\n";

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
