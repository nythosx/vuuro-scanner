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

$fixtureA = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);
$fixtureB = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_lshaped_adversarial.json'), true, 512, JSON_THROW_ON_ERROR);

echo "== Deleting a note/photo from one room of a fused session leaves the other room and the fused render intact ==\n";

[$createStatus, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-fusion-delete', 'unit_id' => 'unit-net-fusion-delete', 'organisation_id' => 'org-net-fusion-delete',
    'purpose' => 'listing', 'occupied' => false,
]);
check('session created (HTTP 201)', $createStatus === 201, "got HTTP $createStatus");
$sessionId = $session['id'] ?? null;
$accessToken = $session['access_token'] ?? null;
if ($sessionId === null || $accessToken === null) {
    fwrite(STDERR, "Cannot continue without a session id/access_token.\n");
    exit(1);
}

$captureA = $fixtureA;
$captureA['structure_origin_m'] = [0.0, 0.0];
[, $afterA] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $captureA], $accessToken);
$roomIdA = $afterA['rooms'][0]['room_id'] ?? null;

$captureB = $fixtureB;
$captureB['structure_origin_m'] = [5.0, 0.0];
[, $afterB] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $captureB], $accessToken);
$roomIdB = $afterB['rooms'][1]['room_id'] ?? null;
check('two distinct fused rooms captured', $roomIdA !== null && $roomIdB !== null && $roomIdA !== $roomIdB);

[, $withNoteA] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes", ['text' => 'note on room A', 'room_id' => $roomIdA], $accessToken);
[, $withNoteB] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes", ['text' => 'note on room B', 'room_id' => $roomIdB], $accessToken);
$noteIdA = null;
$noteIdB = null;
foreach ($withNoteB['notes'] ?? [] as $note) {
    if ($note['room_id'] === $roomIdA) {
        $noteIdA = $note['note_id'];
    }
    if ($note['room_id'] === $roomIdB) {
        $noteIdB = $note['note_id'];
    }
}
check('both room notes attached before the delete under test', $noteIdA !== null && $noteIdB !== null);

[$deleteStatus, $afterDelete] = net_http_json('DELETE', "$baseUrl/scan-sessions/$sessionId/notes/$noteIdA", null, $accessToken);
check('deleting room A\'s note succeeds (HTTP 200)', $deleteStatus === 200, "got HTTP $deleteStatus");
$remainingNoteIds = array_column($afterDelete['notes'] ?? [], 'note_id');
check('room A\'s note is gone', !in_array($noteIdA, $remainingNoteIds, true));
check('room B\'s note is untouched by deleting a different room\'s note', in_array($noteIdB, $remainingNoteIds, true));

[$pngStatus, $pngContentType, $pngBytes] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.png", null, $accessToken);
check('fused PNG export still renders after a per-room note delete (HTTP 200)', $pngStatus === 200, "got HTTP $pngStatus");
check('PNG export still has the real magic bytes', str_starts_with($pngBytes, "\x89PNG"));

[$pdfStatus, , $pdfBytes] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.pdf", null, $accessToken);
check('fused PDF export still renders after a per-room note delete (HTTP 200)', $pdfStatus === 200, "got HTTP $pdfStatus");
check('PDF export still has a real PDF header', str_starts_with($pdfBytes, '%PDF-1.4'));

echo "\n== Delete/update/delete-again sequencing on the same note never resurrects or duplicates it ==\n";

[, $updated] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes/$noteIdB", ['text' => 'edited before delete'], $accessToken);
$editedText = null;
foreach ($updated['notes'] ?? [] as $note) {
    if ($note['note_id'] === $noteIdB) {
        $editedText = $note['text'];
    }
}
check('note text actually changed before the delete under test', $editedText === 'edited before delete', 'got ' . json_encode($editedText));

[$firstDeleteStatus, ] = net_http_json('DELETE', "$baseUrl/scan-sessions/$sessionId/notes/$noteIdB", null, $accessToken);
check('first delete of the edited note succeeds (HTTP 200)', $firstDeleteStatus === 200, "got HTTP $firstDeleteStatus");

[$secondDeleteStatus, ] = net_http_json('DELETE', "$baseUrl/scan-sessions/$sessionId/notes/$noteIdB", null, $accessToken);
check('deleting the same note a second time is rejected with HTTP 404, not a silent no-op 200', $secondDeleteStatus === 404, "got HTTP $secondDeleteStatus");

[$updateAfterDeleteStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes/$noteIdB", ['text' => 'should not land'], $accessToken);
check('updating an already-deleted note is rejected with HTTP 404, not silently recreating it', $updateAfterDeleteStatus === 404, "got HTTP $updateAfterDeleteStatus");

[, $finalSession] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId", null, $accessToken);
$finalNoteIds = array_column($finalSession['notes'] ?? [], 'note_id');
check('the deleted note never comes back under any of the above', !in_array($noteIdB, $finalNoteIds, true));

echo "\n== The update_note rate limit boundary is exactly where the fix set it (600/300s), not lower ==\n";

[, $rateLimitSession] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-notelimit', 'unit_id' => 'unit-net-notelimit', 'organisation_id' => 'org-net-notelimit',
    'purpose' => 'listing', 'occupied' => false,
]);
$rateLimitSessionId = $rateLimitSession['id'] ?? null;
$rateLimitToken = $rateLimitSession['access_token'] ?? null;

if ($rateLimitSessionId !== null && $rateLimitToken !== null) {
    [$rateLimitCaptureStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$rateLimitSessionId/capture", ['raw_capture' => $fixtureA], $rateLimitToken);
    check('a room was captured first so a note exists to update', $rateLimitCaptureStatus === 200, "got HTTP $rateLimitCaptureStatus");

    [, $seedNote] = net_http_json('POST', "$baseUrl/scan-sessions/$rateLimitSessionId/notes", ['text' => 'seed'], $rateLimitToken);
    $seedNoteId = $seedNote['notes'][0]['note_id'] ?? null;
    check('seed note created for the update-boundary probe', $seedNoteId !== null);

    $firstThrottledAt = null;
    for ($i = 0; $i < 605 && $seedNoteId !== null; $i++) {
        [$status, ] = net_http_json('POST', "$baseUrl/scan-sessions/$rateLimitSessionId/notes/$seedNoteId", ['text' => "boundary update $i"], $rateLimitToken);
        if ($status === 429) {
            $firstThrottledAt = $i;
            break;
        }
        if ($status !== 200) {
            check("unexpected non-200/429 status while probing the rate-limit boundary (call $i)", false, "got HTTP $status");
            break;
        }
    }
    check(
        'the 600th call (index 600, zero-based) is the first to be throttled — a 500-room Finish batch (index 0-499) never gets close',
        $firstThrottledAt === 600,
        'got first-throttled-at ' . var_export($firstThrottledAt, true)
    );
}

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
