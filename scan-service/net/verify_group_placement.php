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
        $failures[] = "$label - $detail";
        echo "  [FAIL] $label - $detail\n";
    }
}

$fixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);

[, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-placement',
    'unit_id' => 'unit-net-placement',
    'organisation_id' => 'org-net-placement',
    'purpose' => 'listing',
    'occupied' => false,
]);
$sessionId = $session['id'];
$token = $session['access_token'];

$groupA = $fixture;
$groupA['capture_group_id'] = 'walk-A';
$groupA['structure_origin_m'] = [0.0, 0.0];
net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $groupA], $token);

$groupB = $fixture;
$groupB['capture_group_id'] = 'walk-B';
$groupB['structure_origin_m'] = [20.0, 10.0];
[$captureStatus, $afterB] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $groupB], $token);
check('two whole-unit groups captured', $captureStatus === 200 && count($afterB['rooms']) === 2, 'rooms=' . count($afterB['rooms'] ?? []));

echo "\n== One plan image per group ==\n";
[$groupPngStatus, $groupPngType, $groupPng] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.png?group=walk-A", null, $token);
check('the PNG for one group is returned', $groupPngStatus === 200 && str_starts_with($groupPng, "\x89PNG"), "got $groupPngStatus");
[$wholePngStatus, , $wholePng] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.png", null, $token);
check('the group image differs from the whole-session image', $wholePngStatus === 200 && $groupPng !== $wholePng);
[$noGroupStatus] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.png?group=none", null, $token);
check('group=none with no ungrouped rooms is 404', $noGroupStatus === 404, "got $noGroupStatus");
[$unknownGroupStatus] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.png?group=walk-zzz", null, $token);
check('an unknown group is 404', $unknownGroupStatus === 404, "got $unknownGroupStatus");

echo "\n== Placement with join ==\n";
[$placeStatus, $placed] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/groups/walk-B/placement", [
    'join_to_group_id' => 'walk-A',
    'rotation_deg' => 0.0,
    'translation_m' => [-20.0, -10.0],
], $token);
check('placement returns 200', $placeStatus === 200, "got $placeStatus " . json_encode($placed));
$joinedB = null;
foreach ($placed['rooms'] ?? [] as $room) {
    if (($room['capture_group_id'] ?? null) === 'walk-B') {
        $joinedB = $room;
    }
}
check('group B now carries joined_to_group_id = walk-A', ($joinedB['joined_to_group_id'] ?? null) === 'walk-A', json_encode($joinedB['joined_to_group_id'] ?? null));

echo "\n== Wrong floor is rejected ==\n";
[, $session2] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-placement-2',
    'unit_id' => 'unit-net-placement-2',
    'organisation_id' => 'org-net-placement',
    'purpose' => 'listing',
    'occupied' => false,
]);
$s2 = $session2['id'];
$t2 = $session2['access_token'];
$roomGround = $fixture;
$roomGround['capture_group_id'] = 'g-ground';
$roomGround['structure_origin_m'] = [0.0, 0.0];
net_http_json('POST', "$baseUrl/scan-sessions/$s2/capture", ['raw_capture' => $roomGround, 'floor' => 'Ground'], $t2);
$roomAttic = $fixture;
$roomAttic['capture_group_id'] = 'g-attic';
$roomAttic['structure_origin_m'] = [5.0, 0.0];
net_http_json('POST', "$baseUrl/scan-sessions/$s2/capture", ['raw_capture' => $roomAttic, 'floor' => 'Attic'], $t2);
[$mismatchStatus, $mismatchBody] = net_http_json('POST', "$baseUrl/scan-sessions/$s2/groups/g-attic/placement", [
    'join_to_group_id' => 'g-ground',
    'rotation_deg' => 0.0,
    'translation_m' => [0.0, 0.0],
], $t2);
check('floor mismatch returns 409', $mismatchStatus === 409, "got $mismatchStatus");
check('floor mismatch error code', ($mismatchBody['error'] ?? null) === 'floor_mismatch', json_encode($mismatchBody));

echo "\n== Unknown group is 404 ==\n";
[$unknownStatus] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/groups/no-such-group/placement", [
    'join_to_group_id' => null,
    'rotation_deg' => 0.0,
    'translation_m' => [0.0, 0.0],
], $token);
check('unknown group is 404', $unknownStatus === 404, "got $unknownStatus");

echo "\n== Bad rotation is 422 ==\n";
[$badRotStatus] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/groups/walk-B/placement", [
    'join_to_group_id' => 'walk-A',
    'rotation_deg' => 500.0,
    'translation_m' => [0.0, 0.0],
], $token);
check('rotation above 360 is 422', $badRotStatus === 422, "got $badRotStatus");

echo "\n== Bad translation is 422 ==\n";
[$badTransStatus] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/groups/walk-B/placement", [
    'join_to_group_id' => 'walk-A',
    'rotation_deg' => 0.0,
    'translation_m' => [5000.0, 0.0],
], $token);
check('translation above 1000 is 422', $badTransStatus === 422, "got $badTransStatus");

echo "\n== Detach ==\n";
[$detachStatus, $detached] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/groups/walk-B/placement", [
    'join_to_group_id' => null,
    'rotation_deg' => 0.0,
    'translation_m' => [0.0, 0.0],
], $token);
check('detach returns 200', $detachStatus === 200, "got $detachStatus");
$detachedB = null;
foreach ($detached['rooms'] ?? [] as $room) {
    if (($room['capture_group_id'] ?? null) === 'walk-B') {
        $detachedB = $room;
    }
}
check('detached group no longer has joined_to_group_id', ($detachedB['joined_to_group_id'] ?? null) === null, json_encode($detachedB['joined_to_group_id'] ?? null));

echo "\n== Raw capture with joined_to_group_id is stored ==\n";
[, $session3] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-placement-3',
    'unit_id' => 'unit-net-placement-3',
    'organisation_id' => 'org-net-placement',
    'purpose' => 'listing',
    'occupied' => false,
]);
$s3 = $session3['id'];
$t3 = $session3['access_token'];
$withJoin = $fixture;
$withJoin['capture_group_id'] = 'walk-C';
$withJoin['joined_to_group_id'] = 'walk-A';
$withJoin['structure_origin_m'] = [3.0, 3.0];
[, $afterJoin] = net_http_json('POST', "$baseUrl/scan-sessions/$s3/capture", ['raw_capture' => $withJoin], $t3);
check('joined_to_group_id reaches the stored room', ($afterJoin['rooms'][0]['joined_to_group_id'] ?? null) === 'walk-A', json_encode($afterJoin['rooms'][0]['joined_to_group_id'] ?? null));

echo "\n== Non-numeric translation element rejected ==\n";
[$badElemStatus] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/groups/walk-B/placement", [
    'join_to_group_id' => 'walk-A',
    'rotation_deg' => 0.0,
    'translation_m' => ['abc', 0],
], $token);
check('non-numeric translation element is 422', $badElemStatus === 422, "got $badElemStatus");

echo "\n== A group split across two floors moves one floor at a time ==\n";
[, $s4] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-placement-4', 'unit_id' => 'unit-net-placement-4', 'organisation_id' => 'org-net-placement',
    'purpose' => 'listing', 'occupied' => false,
]);
$s4Id = $s4['id']; $s4Tok = $s4['access_token'];
$multi = $fixture; $multi['capture_group_id'] = 'walk-multi'; $multi['structure_origin_m'] = [0.0, 0.0];
net_http_json('POST', "$baseUrl/scan-sessions/$s4Id/capture", ['raw_capture' => $multi, 'floor' => 'Ground'], $s4Tok);
$multi2 = $fixture; $multi2['capture_group_id'] = 'walk-multi'; $multi2['structure_origin_m'] = [20.0, 0.0];
net_http_json('POST', "$baseUrl/scan-sessions/$s4Id/capture", ['raw_capture' => $multi2, 'floor' => 'Attic'], $s4Tok);
[$multiStatus, $multiAfter] = net_http_json('POST', "$baseUrl/scan-sessions/$s4Id/groups/walk-multi/placement", [
    'join_to_group_id' => null,
    'rotation_deg' => 0.0,
    'translation_m' => [5.0, 0.0],
    'floor' => 'Ground',
], $s4Tok);
check('per-floor placement returns 200', $multiStatus === 200, "got $multiStatus");
$groundOrigin = null; $atticOrigin = null;
foreach ($multiAfter['rooms'] ?? [] as $room) {
    if (($room['floor'] ?? null) === 'Ground') { $groundOrigin = $room['structure_origin_m'][0] ?? null; }
    if (($room['floor'] ?? null) === 'Attic') { $atticOrigin = $room['structure_origin_m'][0] ?? null; }
}
check('Ground room origin shifted by +5 m', $groundOrigin !== null && abs($groundOrigin - 5.0) < 0.01, "origin=$groundOrigin");
check('Attic room origin untouched (still ~20 m)', $atticOrigin !== null && abs($atticOrigin - 20.0) < 0.01, "origin=$atticOrigin");

[$noFloorStatus, $noFloorBody] = net_http_json('POST', "$baseUrl/scan-sessions/$s4Id/groups/walk-multi/placement", [
    'join_to_group_id' => null,
    'rotation_deg' => 0.0,
    'translation_m' => [1.0, 0.0],
], $s4Tok);
check('placing a two-floor group without a floor is 409 floor_required', $noFloorStatus === 409 && ($noFloorBody['error'] ?? null) === 'floor_required', "got $noFloorStatus " . json_encode($noFloorBody));

[$objectTransStatus] = net_http_json('POST', "$baseUrl/scan-sessions/$s4Id/groups/walk-multi/placement", [
    'join_to_group_id' => null,
    'rotation_deg' => 0.0,
    'translation_m' => ['a' => 1.0, 'b' => 0.0],
    'floor' => 'Ground',
], $s4Tok);
check('translation_m sent as an object instead of a list is 422', $objectTransStatus === 422, "got $objectTransStatus");

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
