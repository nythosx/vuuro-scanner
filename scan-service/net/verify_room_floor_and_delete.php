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

function room_by_id(array $plan, string $roomId): array
{
    foreach ($plan['rooms'] ?? [] as $room) {
        if ($room['room_id'] === $roomId) {
            return $room;
        }
    }
    return [];
}

$fixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);
$deviceFixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_device_openings.json'), true, 512, JSON_THROW_ON_ERROR);

[, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-room-edit', 'unit_id' => 'unit-net-room-edit', 'organisation_id' => 'org-net-room-edit',
    'purpose' => 'listing', 'occupied' => false,
]);
$sessionId = $session['id'];
$token = $session['access_token'];

echo "== Doors and windows from a device-shaped capture ==\n";
[$deviceStatus, $devicePlan] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $deviceFixture, 'floor' => 'Attic'], $token);
check('the device-shaped capture is accepted', $deviceStatus === 200, "HTTP $deviceStatus");
check('its doors and windows reach the saved plan', count($devicePlan['rooms'][0]['openings'] ?? []) === 4, json_encode($devicePlan['rooms'][0]['openings'] ?? null));
net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixture, 'floor' => 'Attic'], $token);
[, $thirdPlan] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixture, 'floor' => 'Ground floor'], $token);
$rooms = $thirdPlan['rooms'] ?? [];
check('three rooms are on the scan', count($rooms) === 3, (string) count($rooms));
$duplicateId = $rooms[1]['room_id'] ?? 'missing';
$groundId = $rooms[2]['room_id'] ?? 'missing';

echo "\n== Moving a room to another floor ==\n";
[$floorStatus, $moved] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms/$groundId/floor", ['floor' => '  1st floor '], $token);
check('a room can be moved to another floor', $floorStatus === 200 && (room_by_id($moved, $groundId)['floor'] ?? null) === '1st floor', json_encode(room_by_id($moved, $groundId)['floor'] ?? null));
[$clearStatus, $cleared] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms/$groundId/floor", ['floor' => null], $token);
check('the floor can be cleared with null', $clearStatus === 200 && array_key_exists('floor', room_by_id($cleared, $groundId)) && room_by_id($cleared, $groundId)['floor'] === null, json_encode(room_by_id($cleared, $groundId)));
[$missingStatus] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms/$groundId/floor", [], $token);
check('a request without a floor field is refused', $missingStatus === 422, "HTTP $missingStatus");
[$longStatus] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms/$groundId/floor", ['floor' => str_repeat('a', 61)], $token);
check('a floor name over 60 characters is refused', $longStatus === 422, "HTTP $longStatus");
[$unknownStatus] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms/room-99-nope/floor", ['floor' => 'Attic'], $token);
check('an unknown room is a 422', $unknownStatus === 422, "HTTP $unknownStatus");
[$noTokenStatus] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms/$groundId/floor", ['floor' => 'Attic']);
check('without the access token the floor cannot be changed', in_array($noTokenStatus, [401, 403], true), "HTTP $noTokenStatus");

echo "\n== Deleting a single room ==\n";
net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes", ['text' => 'Leak under the skylight', 'room_id' => $duplicateId], $token);
[$deleteStatus, $afterDelete] = net_http_json('DELETE', "$baseUrl/scan-sessions/$sessionId/rooms/$duplicateId", null, $token);
$remainingIds = array_column($afterDelete['rooms'] ?? [], 'room_id');
check('the duplicate room is removed', $deleteStatus === 200 && !in_array($duplicateId, $remainingIds, true) && count($remainingIds) === 2, json_encode($remainingIds));
$movedNote = null;
foreach ($afterDelete['notes'] ?? [] as $note) {
    if (($note['text'] ?? '') === 'Leak under the skylight') {
        $movedNote = $note;
    }
}
check('its note is kept and moves to the whole unit', $movedNote !== null && array_key_exists('room_id', $movedNote) && $movedNote['room_id'] === null, json_encode($movedNote));
$expectedArea = 0.0;
foreach ($rooms as $room) {
    if ($room['room_id'] !== $duplicateId) {
        $expectedArea += (float) $room['floor_area_m2'];
    }
}
$totalArea = array_sum(array_column($afterDelete['rooms'] ?? [], 'floor_area_m2'));
check('the total area no longer counts the deleted room', abs($totalArea - $expectedArea) < 0.01, "$totalArea vs $expectedArea");
[$againStatus] = net_http_json('DELETE', "$baseUrl/scan-sessions/$sessionId/rooms/$duplicateId", null, $token);
check('deleting it again is a 422, not a 500', $againStatus === 422, "HTTP $againStatus");
[$pngStatus] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.png", null, $token);
check('the plan still renders after the delete', $pngStatus === 200, "HTTP $pngStatus");
net_http_json('DELETE', "$baseUrl/scan-sessions/$sessionId/rooms/" . ($remainingIds[0] ?? 'missing'), null, $token);
[$lastStatus, $lastBody] = net_http_json('DELETE', "$baseUrl/scan-sessions/$sessionId/rooms/" . ($remainingIds[1] ?? 'missing'), null, $token);
check('the last room cannot be deleted on its own', $lastStatus === 409 && ($lastBody['error'] ?? null) === 'last_room', "HTTP $lastStatus " . json_encode($lastBody));

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
