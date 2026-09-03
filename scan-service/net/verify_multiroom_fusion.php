<?php

declare(strict_types=1);

/**
 * Independent net for LIDAR-5/11's structure_origin_m field and the fused
 * PNG rendering path. HTTP only, no adapter/renderer imports.
 *
 * Usage: php net/verify_multiroom_fusion.php [base_url]
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

function point_equal(?array $actual, array $expected): bool
{
    if ($actual === null || count($actual) !== count($expected)) {
        return false;
    }
    foreach ($expected as $i => $value) {
        if (abs((float) $actual[$i] - $value) > 0.001) {
            return false;
        }
    }
    return true;
}

$fixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);

echo "== Multi-room fusion: two rooms each carrying structure_origin_m ==\n";

[$createStatus, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-fusion',
    'unit_id' => 'unit-net-fusion',
    'organisation_id' => 'org-net-fusion',
    'purpose' => 'listing',
    'occupied' => false,
]);
check('session created (HTTP 201)', $createStatus === 201, "got HTTP $createStatus");
$sessionId = $session['id'] ?? null;
$accessToken = $session['access_token'] ?? null;
if ($sessionId === null || $accessToken === null) {
    fwrite(STDERR, "Cannot continue without a session id/access_token.\n");
    exit(1);
}

$captureA = $fixture;
$captureA['structure_origin_m'] = [0.0, 0.0];
[$statusA, $afterFirst] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $captureA], $accessToken);
check('first fused-room capture accepted (HTTP 200)', $statusA === 200, "got HTTP $statusA");
check('first room carries structure_origin_m as sent',
    point_equal($afterFirst['rooms'][0]['structure_origin_m'] ?? null, [0.0, 0.0]),
    'got ' . json_encode($afterFirst['rooms'][0]['structure_origin_m'] ?? null));

$captureB = $fixture;
$captureB['structure_origin_m'] = [6.5, 2.0];
[$statusB, $afterSecond] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $captureB], $accessToken);
check('second fused-room capture accepted (HTTP 200)', $statusB === 200, "got HTTP $statusB");
check('session now has 2 rooms', count($afterSecond['rooms'] ?? []) === 2, 'got ' . count($afterSecond['rooms'] ?? []));
check('second room carries its own distinct structure_origin_m',
    point_equal($afterSecond['rooms'][1]['structure_origin_m'] ?? null, [6.5, 2.0]),
    'got ' . json_encode($afterSecond['rooms'][1]['structure_origin_m'] ?? null));
check('first room still carries its own structure_origin_m after a second capture',
    point_equal($afterSecond['rooms'][0]['structure_origin_m'] ?? null, [0.0, 0.0]),
    'got ' . json_encode($afterSecond['rooms'][0]['structure_origin_m'] ?? null));

[$pngStatus, $pngContentType, $pngBytes] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.png", null, $accessToken);
check('fused floor plan PNG export succeeds (HTTP 200)', $pngStatus === 200, "got HTTP $pngStatus");
check('PNG export has the real PNG content type', $pngContentType === 'image/png', "got $pngContentType");
check('PNG export starts with the real PNG magic bytes', str_starts_with($pngBytes, "\x89PNG"));

echo "\n== Adjacent case: ordinary (non-fused) rooms never carry structure_origin_m ==\n";

[, $ordinarySession] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-nonfused',
    'unit_id' => 'unit-net-nonfused',
    'organisation_id' => 'org-net-nonfused',
    'purpose' => 'listing',
    'occupied' => false,
]);
$ordinarySessionId = $ordinarySession['id'] ?? null;
$ordinaryToken = $ordinarySession['access_token'] ?? null;
[, $ordinaryAfter] = net_http_json('POST', "$baseUrl/scan-sessions/$ordinarySessionId/capture", ['raw_capture' => $fixture], $ordinaryToken);
$ordinaryRoom = $ordinaryAfter['rooms'][0] ?? [];
check('a capture with no structure_origin_m field gets a null structure_origin_m back',
    array_key_exists('structure_origin_m', $ordinaryRoom) && $ordinaryRoom['structure_origin_m'] === null,
    'got ' . (array_key_exists('structure_origin_m', $ordinaryRoom) ? json_encode($ordinaryRoom['structure_origin_m']) : 'missing key entirely'));

echo "\n== Adjacent case: structure_origin_m on a multi-floor capture is rejected, not silently misattributed ==\n";

$twoFloorFixture = $fixture;
$secondFloor = $fixture['floors'][0];
$secondFloor['identifier'] = 'floor-2';
$twoFloorFixture['floors'][] = $secondFloor;
$twoFloorFixture['structure_origin_m'] = [1.0, 1.0];

[, $ambiguousSession] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-ambiguous',
    'unit_id' => 'unit-net-ambiguous',
    'organisation_id' => 'org-net-ambiguous',
    'purpose' => 'listing',
    'occupied' => false,
]);
$ambiguousSessionId = $ambiguousSession['id'] ?? null;
$ambiguousToken = $ambiguousSession['access_token'] ?? null;
[$ambiguousStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$ambiguousSessionId/capture", ['raw_capture' => $twoFloorFixture], $ambiguousToken);
check('a multi-floor capture carrying structure_origin_m is rejected with HTTP 422', $ambiguousStatus === 422, "got HTTP $ambiguousStatus");

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
