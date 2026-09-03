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

echo "\n== Adjacent case: a mixed unit — an ordinary room added to an otherwise-fused session never carries structure_origin_m ==\n";

[$statusC, $afterThird] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixture], $accessToken);
check('third, ordinary (no structure_origin_m) capture into the same fused session is still accepted (HTTP 200)', $statusC === 200, "got HTTP $statusC");
check('session now has 3 rooms', count($afterThird['rooms'] ?? []) === 3, 'got ' . count($afterThird['rooms'] ?? []));
$ordinaryRoom = $afterThird['rooms'][2] ?? [];
check('the third room gets a null structure_origin_m back, not fabricated or inherited from the other two',
    array_key_exists('structure_origin_m', $ordinaryRoom) && $ordinaryRoom['structure_origin_m'] === null,
    'got ' . (array_key_exists('structure_origin_m', $ordinaryRoom) ? json_encode($ordinaryRoom['structure_origin_m']) : 'missing key entirely'));
check('the first two rooms in that same session still carry their own structure_origin_m, unaffected by the third capture',
    point_equal($afterThird['rooms'][0]['structure_origin_m'] ?? null, [0.0, 0.0])
        && point_equal($afterThird['rooms'][1]['structure_origin_m'] ?? null, [6.5, 2.0]),
    'got ' . json_encode(array_column(array_slice($afterThird['rooms'], 0, 2), 'structure_origin_m')));

echo "\n== Adjacent case: structure_origin_m on a multi-floor capture is rejected, not silently misattributed ==\n";

$twoFloorFixture = $fixture;
$secondFloor = $fixture['floors'][0];
$secondFloor['identifier'] = 'floor-2';
$twoFloorFixture['floors'][] = $secondFloor;
$twoFloorFixture['structure_origin_m'] = [1.0, 1.0];

[$ambiguousStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $twoFloorFixture], $accessToken);
check('a multi-floor capture carrying structure_origin_m is rejected with HTTP 422', $ambiguousStatus === 422, "got HTTP $ambiguousStatus");

[, $afterRejection] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId", null, $accessToken);
check('the rejected multi-floor capture left the session at 3 rooms, not partially applied', count($afterRejection['rooms'] ?? []) === 3, 'got ' . count($afterRejection['rooms'] ?? []));

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
