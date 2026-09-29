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

$fixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);

[, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-split', 'unit_id' => 'unit-net-split', 'organisation_id' => 'org-net-split',
    'purpose' => 'listing', 'occupied' => false,
]);
$sessionId = $session['id'];
$token = $session['access_token'];

echo "== Before any capture ==\n";
[$earlyStatus, $earlyBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms/room-01-x/split", ['line_m' => [[0, 0], [1, 1]], 'keep_point_m' => [0.5, 0.2], 'mode' => 'split'], $token);
check('splitting before a capture is a clean 409', $earlyStatus === 409, "got HTTP $earlyStatus " . json_encode($earlyBody));

[$captureStatus, $plan] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixture], $token);
check('capture accepted', $captureStatus === 200, "got HTTP $captureStatus " . json_encode($plan));
if ($captureStatus !== 200) {
    fwrite(STDERR, "
TEST VERDICT: RED
 - capture failed, nothing else can run
");
    exit(1);
}
$room = $plan['rooms'][0];
$roomId = $room['room_id'];
$xs = array_column($room['outline_m'], 0);
$zs = array_column($room['outline_m'], 1);
$midX = (min($xs) + max($xs)) / 2;
$line = [[$midX, min($zs) - 1.0], [$midX, max($zs) + 1.0]];
$keep = [min($xs) + 0.2, (min($zs) + max($zs)) / 2];
$splitUrl = "$baseUrl/scan-sessions/$sessionId/rooms/$roomId/split";

echo "\n== Requests that must be refused ==\n";
[$noTokenStatus] = net_http_json('POST', $splitUrl, ['line_m' => $line, 'keep_point_m' => $keep, 'mode' => 'split']);
check('no access token is refused', in_array($noTokenStatus, [401, 403], true), "got HTTP $noTokenStatus");
[$badLineStatus, $badLineBody] = net_http_json('POST', $splitUrl, ['line_m' => [[0, 0]], 'keep_point_m' => $keep, 'mode' => 'split'], $token);
check('a one-point line is a 422 invalid_split_line', $badLineStatus === 422 && ($badLineBody['error'] ?? null) === 'invalid_split_line', json_encode($badLineBody));
[$nanStatus] = net_http_raw_literal('POST', $splitUrl, '{"line_m":[[0,0],[1e999,1]],"keep_point_m":[0,0],"mode":"split"}', $token);
check('a non-finite coordinate is a 422', $nanStatus === 422, "got HTTP $nanStatus");
[$badModeStatus] = net_http_json('POST', $splitUrl, ['line_m' => $line, 'keep_point_m' => $keep, 'mode' => 'merge'], $token);
check('an unknown mode is a 422', $badModeStatus === 422, "got HTTP $badModeStatus");
[$missStatus, $missBody] = net_http_json('POST', $splitUrl, ['line_m' => [[max($xs) + 5, 0], [max($xs) + 5, 1]], 'keep_point_m' => $keep, 'mode' => 'split'], $token);
check('a line that misses the room is a 422 invalid_split with a readable message', $missStatus === 422 && str_contains(json_encode($missBody), 'cross'), json_encode($missBody));
[$unknownStatus] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms/room-99-nope/split", ['line_m' => $line, 'keep_point_m' => $keep, 'mode' => 'split'], $token);
check('an unknown room is a 422', $unknownStatus === 422, "got HTTP $unknownStatus");
[$undoEmptyStatus] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/room-splits/undo", [], $token);
check('undo with nothing to undo is a 409', $undoEmptyStatus === 409, "got HTTP $undoEmptyStatus");

echo "\n== Split, export, undo ==\n";
[$splitStatus, $split] = net_http_json('POST', $splitUrl, ['line_m' => $line, 'keep_point_m' => $keep, 'mode' => 'split'], $token);
check('a line across the room splits it (HTTP 200)', $splitStatus === 200, "got HTTP $splitStatus " . json_encode($split));
check('the session now has two rooms', count($split['rooms'] ?? []) === 2);
$areaSum = array_sum(array_column($split['rooms'] ?? [], 'floor_area_m2'));
check('the two parts add up to the original area', abs($areaSum - $room['floor_area_m2']) < 0.05, "$areaSum vs {$room['floor_area_m2']}");
check('the kept part keeps the room id', ($split['rooms'][0]['room_id'] ?? null) === $roomId);
check('both parts carry an open edge', count($split['rooms'][0]['open_edges'] ?? []) === 1 && count($split['rooms'][1]['open_edges'] ?? []) === 1);

[$svgStatus, , $svg] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.svg?style=funda", null, $token);
check('the Funda SVG export shows the cut as an open edge', $svgStatus === 200 && substr_count($svg, 'class="open-edge"') === 2, "HTTP $svgStatus, " . substr_count($svg, 'class="open-edge"') . ' open edges');
[$pngStatus] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.png", null, $token);
[$pdfStatus] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.pdf", null, $token);
check('PNG and PDF exports still render', $pngStatus === 200 && $pdfStatus === 200, "png=$pngStatus pdf=$pdfStatus");

[$getStatus, $fetched] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId", null, $token);
$fetchedRooms = $fetched['floor_plan']['rooms'] ?? $fetched['rooms'] ?? [];
check('the split is stored, not just returned', $getStatus === 200 && count($fetchedRooms) === 2, 'rooms=' . count($fetchedRooms));

[$undoStatus, $undone] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/room-splits/undo", [], $token);
check('undo restores the single room', $undoStatus === 200 && count($undone['rooms'] ?? []) === 1 && abs($undone['rooms'][0]['floor_area_m2'] - $room['floor_area_m2']) < 1e-9, "HTTP $undoStatus");

[$trimStatus, $trimmed] = net_http_json('POST', $splitUrl, ['line_m' => $line, 'keep_point_m' => $keep, 'mode' => 'trim'], $token);
check('trim keeps one smaller room', $trimStatus === 200 && count($trimmed['rooms'] ?? []) === 1 && $trimmed['rooms'][0]['floor_area_m2'] < $room['floor_area_m2'], "HTTP $trimStatus");

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
