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

function room_by_id(array $plan, string $id): ?array
{
    foreach ($plan['rooms'] ?? [] as $room) {
        if (($room['room_id'] ?? null) === $id) {
            return $room;
        }
    }
    return null;
}

$fixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);
$deviceFixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_device_openings.json'), true, 512, JSON_THROW_ON_ERROR);

[, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-rescan', 'unit_id' => 'unit-net-rescan', 'organisation_id' => 'org-net-rescan',
    'purpose' => 'listing', 'occupied' => false,
]);
$sessionId = $session['id'];
$token = $session['access_token'];

[, $first] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixture, 'floor' => 'Attic'], $token);
$atticId = $first['rooms'][0]['room_id'];
$atticLabel = $first['rooms'][0]['label'];
$atticArea = $first['rooms'][0]['floor_area_m2'];
net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes", ['text' => 'leak under the window', 'room_id' => $atticId], $token);
net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/photos", ['url' => 'https://example.com/attic.jpg', 'caption' => 'attic', 'room_id' => $atticId], $token);
[, $second] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixture, 'floor' => 'Ground floor'], $token);
$groundId = $second['rooms'][1]['room_id'];

echo "== Replace an existing room ==\n";
$replacement = $deviceFixture;
$replacement['replaces_room_id'] = $atticId;
[$replaceStatus, $replaced] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $replacement, 'floor' => 'Attic'], $token);
check('replacing a room is accepted', $replaceStatus === 200, "got HTTP $replaceStatus " . json_encode($replaced));
check('the room count stays the same', count($replaced['rooms'] ?? []) === 2, (string) count($replaced['rooms'] ?? []));
$newAttic = room_by_id($replaced, $atticId);
check('the replaced room keeps its room_id and its place', ($replaced['rooms'][0]['room_id'] ?? null) === $atticId);
check('the replaced room has the new geometry', $newAttic !== null && abs((float) $newAttic['floor_area_m2'] - (float) $atticArea) > 0.01, json_encode([$atticArea, $newAttic['floor_area_m2'] ?? null]));
check('an automatic name does not overwrite the old name', ($newAttic['label'] ?? null) === $atticLabel, json_encode($newAttic['label'] ?? null));
check('the note stays on the replaced room', ($replaced['notes'][0]['room_id'] ?? null) === $atticId, json_encode($replaced['notes'] ?? []));
check('the photo stays on the replaced room', ($replaced['photos'][0]['room_id'] ?? null) === $atticId, json_encode($replaced['photos'] ?? []));
check('the other room is untouched', room_by_id($replaced, $groundId) !== null);

echo "\n== Add as a new room ==\n";
[$addStatus, $added] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixture, 'floor' => 'Attic'], $token);
check('adding without replaces_room_id adds a room', $addStatus === 200 && count($added['rooms'] ?? []) === 3, "got HTTP $addStatus, " . count($added['rooms'] ?? []) . ' rooms');

echo "\n== Refused replacements ==\n";
$unknown = $fixture;
$unknown['replaces_room_id'] = 'room-99-does-not-exist';
[$unknownStatus, $unknownBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $unknown, 'floor' => 'Attic'], $token);
check('replacing a room that does not exist is 422 unknown_room_id', $unknownStatus === 422 && ($unknownBody['error'] ?? null) === 'unknown_room_id', "got HTTP $unknownStatus " . json_encode($unknownBody));
$wrongFloor = $fixture;
$wrongFloor['replaces_room_id'] = $atticId;
[$wrongFloorStatus, $wrongFloorBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $wrongFloor, 'floor' => 'Ground floor'], $token);
check('replacing a room with a scan on another floor is 409', $wrongFloorStatus === 409 && ($wrongFloorBody['error'] ?? null) === 'replace_floor_mismatch', "got HTTP $wrongFloorStatus " . json_encode($wrongFloorBody));
$badId = $fixture;
$badId['replaces_room_id'] = 'bad id with spaces';
[$badIdStatus] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $badId, 'floor' => 'Attic'], $token);
check('a malformed replaces_room_id is 422', $badIdStatus === 422, "got HTTP $badIdStatus");
[, $afterRefused] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId", null, $token);
check('refused replacements change nothing', count($afterRefused['rooms'] ?? []) === 3, (string) count($afterRefused['rooms'] ?? []));

echo "\n== Replace during a whole-unit continue ==\n";
$walkTile = $fixture;
$walkTile['capture_group_id'] = 'walk-rescan';
$walkTile['replaces_room_id'] = $groundId;
[$tileStatus, $afterTile] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $walkTile, 'floor' => 'Ground floor'], $token);
check('the walkthrough tile replaces the room in place', $tileStatus === 200 && count($afterTile['rooms'] ?? []) === 3 && room_by_id($afterTile, $groundId) !== null, "got HTTP $tileStatus " . json_encode(array_column($afterTile['rooms'] ?? [], 'room_id')));
$fused = $deviceFixture;
$fused['capture_group_id'] = 'walk-rescan';
$fused['replaces_room_id'] = $groundId;
[$fusedStatus, $afterFused] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms", ['captures' => [['raw_capture' => $fused, 'floor' => 'Ground floor']]], $token);
$fusedIds = array_column($afterFused['rooms'] ?? [], 'room_id');
check('finishing the walkthrough keeps the replaced room_id', $fusedStatus === 200 && in_array($groundId, $fusedIds, true), "got HTTP $fusedStatus " . json_encode($fusedIds));
check('finishing the walkthrough keeps every other room', count($fusedIds) === 3 && in_array($atticId, $fusedIds, true), json_encode($fusedIds));
check('no room id appears twice', count(array_unique($fusedIds)) === count($fusedIds), json_encode($fusedIds));

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
