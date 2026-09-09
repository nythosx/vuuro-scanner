<?php

declare(strict_types=1);

/**
 * Independent net for LIDAR-5/11's POST /scan-sessions/{id}/rooms — the
 * replace-rooms endpoint that lets a client upload tiles immediately, then
 * supersede them with a StructureBuilder-fused set once merge succeeds,
 * without double-counting rooms. HTTP only, no adapter/repository imports.
 *
 * Usage: php net/verify_replace_rooms.php [base_url]
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

echo "== Tiles uploaded first, then superseded by a fused pair via PUT /rooms ==\n";

[$createStatus, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-replace', 'unit_id' => 'unit-net-replace', 'organisation_id' => 'org-net-replace',
    'purpose' => 'listing', 'occupied' => false,
]);
check('session created (HTTP 201)', $createStatus === 201, "got HTTP $createStatus");
$sessionId = $session['id'] ?? null;
$accessToken = $session['access_token'] ?? null;
if ($sessionId === null || $accessToken === null) {
    fwrite(STDERR, "Cannot continue without a session id/access_token.\n");
    exit(1);
}

[$tileAStatus, $afterTileA] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixture], $accessToken);
check('first tile capture accepted (HTTP 200)', $tileAStatus === 200, "got HTTP $tileAStatus");
[$tileBStatus, $afterTileB] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixture], $accessToken);
check('second tile capture accepted (HTTP 200)', $tileBStatus === 200, "got HTTP $tileBStatus");
check('session has 2 tile rooms before replace', count($afterTileB['rooms'] ?? []) === 2, 'got ' . count($afterTileB['rooms'] ?? []));

[$noteStatus, $afterNote] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes", ['text' => 'note attached before fusion'], $accessToken);
check('a note attached before replace is accepted (HTTP 201)', $noteStatus === 201, "got HTTP $noteStatus");

$captureA = $fixture;
$captureA['structure_origin_m'] = [0.0, 0.0];
$captureB = $fixture;
$captureB['structure_origin_m'] = [6.5, 2.0];

[$replaceStatus, $afterReplace] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms", [
    'captures' => [
        ['raw_capture' => $captureA],
        ['raw_capture' => $captureB],
    ],
], $accessToken);
check('replace-rooms accepted (HTTP 200)', $replaceStatus === 200, "got HTTP $replaceStatus");
check('session still has exactly 2 rooms after replace, not 4 (no double-counting)', count($afterReplace['rooms'] ?? []) === 2, 'got ' . count($afterReplace['rooms'] ?? []));
check('first replaced room carries the fused structure_origin_m', ($afterReplace['rooms'][0]['structure_origin_m'] ?? null) == [0.0, 0.0], 'got ' . json_encode($afterReplace['rooms'][0]['structure_origin_m'] ?? null));
check('second replaced room carries its own distinct structure_origin_m', ($afterReplace['rooms'][1]['structure_origin_m'] ?? null) == [6.5, 2.0], 'got ' . json_encode($afterReplace['rooms'][1]['structure_origin_m'] ?? null));
check('the note attached before replace survives (photos/notes preserved)', count($afterReplace['notes'] ?? []) === 1 && ($afterReplace['notes'][0]['text'] ?? null) === 'note attached before fusion', 'got ' . json_encode($afterReplace['notes'] ?? []));

[$fetchStatus, $refetched] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId", null, $accessToken);
check('re-fetching the session sees the replaced rooms, not the old tiles', $fetchStatus === 200 && count($refetched['rooms'] ?? []) === 2, 'got ' . count($refetched['rooms'] ?? []) . ' rooms');

echo "\n== Adjacent case: replace-rooms on a session with no floor plan yet is rejected ==\n";

[, $emptySession] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-replace-empty', 'unit_id' => 'unit-net-replace-empty', 'organisation_id' => 'org-net-replace',
    'purpose' => 'listing', 'occupied' => false,
]);
[$emptyReplaceStatus, $emptyReplaceBody] = net_http_json('POST', "$baseUrl/scan-sessions/{$emptySession['id']}/rooms", [
    'captures' => [['raw_capture' => $fixture]],
], $emptySession['access_token']);
check('replace-rooms on a session with no prior capture is rejected (HTTP 409)', $emptyReplaceStatus === 409, "got HTTP $emptyReplaceStatus, body " . json_encode($emptyReplaceBody));

echo "\n== Adjacent case: malformed / missing captures[] is a clean 422, not a fatal error ==\n";

[$missingStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms", [], $accessToken);
check('missing captures[] is rejected (HTTP 422)', $missingStatus === 422, "got HTTP $missingStatus");

[$notListStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms", ['captures' => ['not' => 'a list']], $accessToken);
check('a non-list captures[] is rejected (HTTP 422)', $notListStatus === 422, "got HTTP $notListStatus");

[$badRawStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms", ['captures' => [['nope' => true]]], $accessToken);
check('a captures[] entry missing raw_capture is rejected (HTTP 422)', $badRawStatus === 422, "got HTTP $badRawStatus");

[, $afterBadRequests] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId", null, $accessToken);
check('rejected replace-rooms calls left the session untouched at 2 rooms', count($afterBadRequests['rooms'] ?? []) === 2, 'got ' . count($afterBadRequests['rooms'] ?? []));

echo "\n== Adjacent case: wrong token is rejected, not allowed to replace another session's rooms ==\n";

[, $otherSession] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-replace-other', 'unit_id' => 'unit-net-replace-other', 'organisation_id' => 'org-net-replace',
    'purpose' => 'listing', 'occupied' => false,
]);
[$wrongTokenStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms", [
    'captures' => [['raw_capture' => $fixture]],
], $otherSession['access_token']);
check('a different session\'s token cannot replace this session\'s rooms (HTTP 401)', $wrongTokenStatus === 401, "got HTTP $wrongTokenStatus");

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
