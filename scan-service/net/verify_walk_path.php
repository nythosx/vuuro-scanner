<?php

declare(strict_types=1);

/**
 * Independent net for the walk-path-on-the-2D-sheet feature (Mark's
 * doors/windows/walk-through punch-list item #4). HTTP only, no
 * adapter/renderer imports.
 *
 * Usage: php net/verify_walk_path.php [base_url]
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

$fixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);

echo "== A capture with a walk_path carries walk_path_m through to the session, PNG, and PDF ==\n";

[, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-walkpath', 'unit_id' => 'unit-net-walkpath', 'organisation_id' => 'org-net-walkpath',
    'purpose' => 'listing', 'occupied' => false,
]);
$sessionId = $session['id'];
$accessToken = $session['access_token'];

$withPath = $fixture;
$withPath['walk_path'] = [[0.2, 0.0, 0.2], [1.0, 0.0, 0.4], [1.8, 0.0, 0.6], [2.4, 0.0, 1.0]];
[$captureStatus, $afterCapture] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $withPath], $accessToken);
check('capture with walk_path accepted (HTTP 200)', $captureStatus === 200, "got HTTP $captureStatus");
check('walk_path_m has the same point count as recorded', count($afterCapture['rooms'][0]['walk_path_m'] ?? []) === 4, 'got ' . count($afterCapture['rooms'][0]['walk_path_m'] ?? []));

[$pngStatus, $pngContentType, $pngWithPath] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.png", null, $accessToken);
check('PNG export with a walk path succeeds (HTTP 200)', $pngStatus === 200, "got HTTP $pngStatus");
check('PNG export has the real PNG content type', $pngContentType === 'image/png', "got $pngContentType");

[$pdfStatus, , $pdfBytes] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.pdf", null, $accessToken);
check('PDF export with a walk path succeeds (HTTP 200)', $pdfStatus === 200, "got HTTP $pdfStatus");
check('PDF text mentions the recorded walk path point count', str_contains($pdfBytes, 'walk path: 4 point\\(s\\) recorded'), 'PDF text did not mention the walk path');

echo "\n== Adjacent case: a room with no walk_path renders a visibly different PNG (the path is actually drawn, not a no-op) ==\n";

[, $noPathSession] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-walkpath-none', 'unit_id' => 'unit-net-walkpath-none', 'organisation_id' => 'org-net-walkpath',
    'purpose' => 'listing', 'occupied' => false,
]);
net_http_json('POST', "$baseUrl/scan-sessions/{$noPathSession['id']}/capture", ['raw_capture' => $fixture], $noPathSession['access_token']);
[, , $pngNoPath] = net_http_raw('GET', "$baseUrl/scan-sessions/{$noPathSession['id']}/export/floorplan.png", null, $noPathSession['access_token']);
check('a session with a walk path renders different PNG bytes than one without', $pngWithPath !== $pngNoPath);

echo "\n== Adjacent case: a fused (2-room) session with per-room walk paths renders without throwing ==\n";

[, $fusedSession] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-walkpath-fused', 'unit_id' => 'unit-net-walkpath-fused', 'organisation_id' => 'org-net-walkpath',
    'purpose' => 'listing', 'occupied' => false,
]);
$fusedId = $fusedSession['id'];
$fusedToken = $fusedSession['access_token'];

$fusedA = $fixture;
$fusedA['structure_origin_m'] = [0.0, 0.0];
$fusedA['walk_path'] = [[0.3, 0.0, 0.3], [1.2, 0.0, 0.5]];
net_http_json('POST', "$baseUrl/scan-sessions/$fusedId/capture", ['raw_capture' => $fusedA], $fusedToken);

$fusedB = $fixture;
$fusedB['structure_origin_m'] = [6.0, 1.0];
$fusedB['walk_path'] = [[0.4, 0.0, 0.2], [1.0, 0.0, 0.9]];
net_http_json('POST', "$baseUrl/scan-sessions/$fusedId/capture", ['raw_capture' => $fusedB], $fusedToken);

[$fusedPngStatus, , $fusedPngBytes] = net_http_raw('GET', "$baseUrl/scan-sessions/$fusedId/export/floorplan.png", null, $fusedToken);
check('fused PNG with per-room walk paths succeeds (HTTP 200)', $fusedPngStatus === 200, "got HTTP $fusedPngStatus");
check('fused PNG has the real PNG magic bytes', str_starts_with($fusedPngBytes, "\x89PNG"));

echo "\n== Adjacent case: an oversized walk_path[] is a clean 422, not a fatal error ==\n";

$hugePath = $fixture;
$hugePath['walk_path'] = array_fill(0, 1001, [0.0, 0.0, 0.0]);
[$hugeStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $hugePath], $accessToken);
check('an oversized walk_path[] is rejected (HTTP 422), not a crash', $hugeStatus === 422, "got HTTP $hugeStatus");

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
