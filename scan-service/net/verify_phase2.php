<?php

declare(strict_types=1);

/**
 * Independent net for Phase 2 groundwork: multi-room stitching and
 * photos/notes attachment. Same rules as net/verify_phase1.php — HTTP only,
 * no adapter/repository imports, expected values re-derived independently.
 *
 * Usage: php net/verify_phase2.php [base_url]
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

// Independently-coded shoelace math, deliberately re-written here rather
// than reused from net/verify_phase1.php's copy — same rationale as Phase 1:
// the net must not share a bug with the code (or with itself) it's checking.
function shoelace_area(array $xz): float
{
    $total = 0.0;
    $n = count($xz);
    for ($i = 0; $i < $n; $i++) {
        $j = ($i + 1) % $n;
        $total += ($xz[$i][0] * $xz[$j][1]) - ($xz[$j][0] * $xz[$i][1]);
    }
    return abs($total) / 2.0;
}

function to_xz(array $corners3d): array
{
    return array_map(static fn ($p) => [(float) $p[0], (float) $p[2]], $corners3d);
}

echo "== Multi-room: two sequential single-room captures stitch into one FloorPlan ==\n";

$fixtureA = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);
$fixtureB = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_lshaped_adversarial.json'), true, 512, JSON_THROW_ON_ERROR);
$wantAreaA = shoelace_area(to_xz($fixtureA['floors'][0]['polygonCorners']));
$wantAreaB = shoelace_area(to_xz($fixtureB['floors'][0]['polygonCorners']));

[$createStatus, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-p2',
    'unit_id' => 'unit-net-p2',
    'organisation_id' => 'org-net-p2',
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

[, $afterFirst] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixtureA], $accessToken);
check('first capture produced exactly 1 room', count($afterFirst['rooms'] ?? []) === 1, 'got ' . count($afterFirst['rooms'] ?? []));
check('first room area matches independent shoelace calc',
    approx((float) ($afterFirst['rooms'][0]['floor_area_m2'] ?? -1), $wantAreaA),
    'got ' . ($afterFirst['rooms'][0]['floor_area_m2'] ?? 'null') . " expected " . round($wantAreaA, 4));
$firstRoomIdAfterFirstCapture = $afterFirst['rooms'][0]['room_id'] ?? null;

[, $afterSecond] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixtureB], $accessToken);
check('second capture brings the session to exactly 2 rooms (stitched, not overwritten)',
    count($afterSecond['rooms'] ?? []) === 2, 'got ' . count($afterSecond['rooms'] ?? []));

check('room 1 from the first capture is untouched by the second capture',
    ($afterSecond['rooms'][0]['room_id'] ?? null) === $firstRoomIdAfterFirstCapture
        && approx((float) ($afterSecond['rooms'][0]['floor_area_m2'] ?? -1), $wantAreaA),
    'first room changed after a second, unrelated capture — this is exactly the adjacent-case failure shape (fixing room 2 broke room 1)');

check('room 2 area matches independent shoelace calc for the L-shaped fixture',
    approx((float) ($afterSecond['rooms'][1]['floor_area_m2'] ?? -1), $wantAreaB),
    'got ' . ($afterSecond['rooms'][1]['floor_area_m2'] ?? 'null') . " expected " . round($wantAreaB, 4));

check('room_id is unique across both rooms in the session',
    ($afterSecond['rooms'][0]['room_id'] ?? 'a') !== ($afterSecond['rooms'][1]['room_id'] ?? 'b'));

[$getStatus, $refetched] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId", null, $accessToken);
check('GET after two captures still returns 2 rooms', count($refetched['rooms'] ?? []) === 2, 'got ' . count($refetched['rooms'] ?? []));
check('GET result matches the second capture response exactly', $refetched === $afterSecond);

echo "\n== Photos and notes attach to the same unit package ==\n";

[$photoStatus, $withPhoto] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/photos", [
    'url' => 'https://example.invalid/net-test-photo.jpg',
    'caption' => 'Net test photo',
], $accessToken);
check('photo attach returns HTTP 201', $photoStatus === 201, "got HTTP $photoStatus");
check('photo is appended, not replacing rooms', count($withPhoto['photos'] ?? []) === 1 && count($withPhoto['rooms'] ?? []) === 2);

[$noteStatus, $withNote] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes", [
    'text' => 'Net test note',
], $accessToken);
check('note attach returns HTTP 201', $noteStatus === 201, "got HTTP $noteStatus");
check('note is appended, rooms and the earlier photo both survive',
    count($withNote['notes'] ?? []) === 1 && count($withNote['photos'] ?? []) === 1 && count($withNote['rooms'] ?? []) === 2);

echo "\n== Adversarial: photos/notes must not attach before any capture exists ==\n";

[$emptyCreateStatus, $emptySession] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-p2-empty',
    'unit_id' => 'unit-net-p2-empty',
    'organisation_id' => 'org-net-p2-empty',
    'purpose' => 'listing',
    'occupied' => false,
]);
check('empty session created for the negative case', $emptyCreateStatus === 201);
$emptySessionId = $emptySession['id'] ?? null;
$emptySessionToken = $emptySession['access_token'] ?? null;

if ($emptySessionId !== null) {
    [$photoOnEmptyStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$emptySessionId/photos", ['url' => 'https://example.invalid/x.jpg'], $emptySessionToken);
    check('attaching a photo before any capture is rejected (HTTP 409)', $photoOnEmptyStatus === 409, "got HTTP $photoOnEmptyStatus");

    [$noteOnEmptyStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$emptySessionId/notes", ['text' => 'orphan note'], $emptySessionToken);
    check('attaching a note before any capture is rejected (HTTP 409)', $noteOnEmptyStatus === 409, "got HTTP $noteOnEmptyStatus");
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
