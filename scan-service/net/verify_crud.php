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
$replacementFixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_lshaped_adversarial.json'), true, 512, JSON_THROW_ON_ERROR);
$suffix = substr(md5((string) microtime(true)), 0, 8);

echo "== Session CRUD ==\n";

[$createStatus, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => "prop-crud-$suffix", 'unit_id' => "unit-crud-$suffix", 'organisation_id' => "org-crud-$suffix",
    'purpose' => 'listing', 'occupied' => false,
]);
check('CREATE session succeeds (HTTP 200/201)', in_array($createStatus, [200, 201], true), "got HTTP $createStatus");
check('CREATE session returns an id', !empty($session['id']));
check('CREATE session returns an access_token', !empty($session['access_token']));
$sessionId = $session['id'];
$accessToken = $session['access_token'];

net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixture], $accessToken);

[$readStatus, $readBody] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId", null, $accessToken);
check('READ session succeeds (HTTP 200)', $readStatus === 200, "got HTTP $readStatus");
check('READ session returns the same session id', ($readBody['scan_session_id'] ?? null) === $sessionId);

[$readWrongTokenStatus, ] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId", null, 'wrong-token');
check('READ session with a wrong access token is rejected (HTTP 401/403)', in_array($readWrongTokenStatus, [401, 403], true), "got HTTP $readWrongTokenStatus");

[$updateStatus, $rotated] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rotate-token", null, $accessToken);
check('UPDATE session (rotate-token) succeeds (HTTP 200)', $updateStatus === 200, "got HTTP $updateStatus");
check('UPDATE session (rotate-token) returns a different token', ($rotated['access_token'] ?? null) !== $accessToken);
$accessToken = $rotated['access_token'];

[$deleteStatus, ] = net_http_json('DELETE', "$baseUrl/scan-sessions/$sessionId", null, $accessToken);
check('DELETE session succeeds (HTTP 200)', $deleteStatus === 200, "got HTTP $deleteStatus");

[$readAfterDeleteStatus, ] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId", null, $accessToken);
check('READ session after DELETE fails (HTTP 401/404)', in_array($readAfterDeleteStatus, [401, 404], true), "got HTTP $readAfterDeleteStatus");

[$deleteAgainStatus, ] = net_http_json('DELETE', "$baseUrl/scan-sessions/$sessionId", null, $accessToken);
check('DELETE session a second time is a clean failure, not a crash (HTTP 401/404)', in_array($deleteAgainStatus, [401, 404], true), "got HTTP $deleteAgainStatus");
echo "\n";

[, $s] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => "prop-crud2-$suffix", 'unit_id' => "unit-crud2-$suffix", 'organisation_id' => "org-crud2-$suffix",
    'purpose' => 'listing', 'occupied' => false,
]);
$sessionId = $s['id'];
$accessToken = $s['access_token'];

echo "== Room CRUD (Create/Read/Update — no per-room Delete endpoint exists; see note) ==\n";

[$captureStatus, $afterCapture] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixture], $accessToken);
check('CREATE room via capture succeeds (HTTP 200/201)', in_array($captureStatus, [200, 201], true), "got HTTP $captureStatus");
check('CREATE room via capture returns one room', count($afterCapture['rooms'] ?? []) === 1, 'got ' . count($afterCapture['rooms'] ?? []));
$roomId = $afterCapture['rooms'][0]['room_id'];

[$readRoomStatus, $readRoomBody] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId", null, $accessToken);
check('READ room (via session) succeeds (HTTP 200)', $readRoomStatus === 200, "got HTTP $readRoomStatus");
check('READ room finds the room just created', ($readRoomBody['rooms'][0]['room_id'] ?? null) === $roomId);

[$updateTypeStatus, $afterTypeUpdate] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms/$roomId/room-type", ['room_type' => 'kitchen'], $accessToken);
check('UPDATE room type succeeds (HTTP 200)', $updateTypeStatus === 200, "got HTTP $updateTypeStatus");
check('UPDATE room type is reflected', ($afterTypeUpdate['rooms'][0]['room_type']['confirmed'] ?? null) === 'kitchen');

[$updateLabelStatus, $afterLabelUpdate] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms/$roomId/label", ['label' => 'Primary bedroom'], $accessToken);
check('UPDATE room label succeeds (HTTP 200)', $updateLabelStatus === 200, "got HTTP $updateLabelStatus");
check('UPDATE room label is reflected', ($afterLabelUpdate['rooms'][0]['label'] ?? null) === 'Primary bedroom');

[$updateBadRoomStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms/not-a-real-room/label", ['label' => 'x'], $accessToken);
check('UPDATE label on an unknown room_id fails cleanly (HTTP 422)', $updateBadRoomStatus === 422, "got HTTP $updateBadRoomStatus");

[$replaceStatus, $afterReplace] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms", ['captures' => [['raw_capture' => $replacementFixture]]], $accessToken);
check('REPLACE rooms (the de-facto room removal path) succeeds (HTTP 200)', $replaceStatus === 200, "got HTTP $replaceStatus");
check('REPLACE rooms drops the old room_id', ($afterReplace['rooms'][0]['room_id'] ?? null) !== $roomId);
$roomId = $afterReplace['rooms'][0]['room_id'];
echo "\n";

echo "== Photo CRUD (Create/Read/Delete — no Update endpoint exists; see note) ==\n";

[$addPhotoStatus, $afterPhoto] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/photos", ['url' => 'https://example.com/crud-a.jpg', 'caption' => 'first', 'room_id' => $roomId], $accessToken);
check('CREATE photo succeeds (HTTP 200/201)', in_array($addPhotoStatus, [200, 201], true), "got HTTP $addPhotoStatus");
check('CREATE photo is attached to the given room', ($afterPhoto['photos'][0]['room_id'] ?? null) === $roomId);
$photoId = $afterPhoto['photos'][0]['photo_id'];

[$readPhotoStatus, $readPhotoBody] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId", null, $accessToken);
check('READ photo (via session) succeeds (HTTP 200)', $readPhotoStatus === 200, "got HTTP $readPhotoStatus");
check('READ photo finds the photo just created', ($readPhotoBody['photos'][0]['photo_id'] ?? null) === $photoId);

[$deletePhotoStatus, $afterPhotoDelete] = net_http_json('DELETE', "$baseUrl/scan-sessions/$sessionId/photos/$photoId", null, $accessToken);
check('DELETE photo succeeds (HTTP 200)', $deletePhotoStatus === 200, "got HTTP $deletePhotoStatus");
check('DELETE photo actually removes it', count(array_filter($afterPhotoDelete['photos'], fn ($p) => $p['photo_id'] === $photoId)) === 0);

[$deletePhotoAgainStatus, ] = net_http_json('DELETE', "$baseUrl/scan-sessions/$sessionId/photos/$photoId", null, $accessToken);
check('DELETE photo a second time is a clean 404', $deletePhotoAgainStatus === 404, "got HTTP $deletePhotoAgainStatus");
echo "\n";

echo "== Note CRUD ==\n";

[$addNoteStatus, $afterNote] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes", ['text' => 'original text', 'room_id' => $roomId], $accessToken);
check('CREATE note succeeds (HTTP 200/201)', in_array($addNoteStatus, [200, 201], true), "got HTTP $addNoteStatus");
check('CREATE note is attached to the given room', ($afterNote['notes'][0]['room_id'] ?? null) === $roomId);
$noteId = $afterNote['notes'][0]['note_id'];

[$readNoteStatus, $readNoteBody] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId", null, $accessToken);
check('READ note (via session) succeeds (HTTP 200)', $readNoteStatus === 200, "got HTTP $readNoteStatus");
check('READ note finds the note just created', ($readNoteBody['notes'][0]['text'] ?? null) === 'original text');

[$updateNoteStatus, $afterNoteUpdate] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes/$noteId", ['text' => 'edited text'], $accessToken);
check('UPDATE note succeeds (HTTP 200)', $updateNoteStatus === 200, "got HTTP $updateNoteStatus");
check('UPDATE note changes the text in place (same note_id)', ($afterNoteUpdate['notes'][0]['note_id'] ?? null) === $noteId && ($afterNoteUpdate['notes'][0]['text'] ?? null) === 'edited text');
check('UPDATE note stamps updated_at', !empty($afterNoteUpdate['notes'][0]['updated_at'] ?? null));
check('UPDATE note does not create a second note', count($afterNoteUpdate['notes']) === 1, 'got ' . count($afterNoteUpdate['notes']));

[$updateNoteMissingTextStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes/$noteId", [], $accessToken);
check('UPDATE note with no text field is rejected (HTTP 422)', $updateNoteMissingTextStatus === 422, "got HTTP $updateNoteMissingTextStatus");

[$updateUnknownNoteStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes/not-a-real-note", ['text' => 'x'], $accessToken);
check('UPDATE an unknown note_id is a clean 404', $updateUnknownNoteStatus === 404, "got HTTP $updateUnknownNoteStatus");

[$deleteNoteStatus, $afterNoteDelete] = net_http_json('DELETE', "$baseUrl/scan-sessions/$sessionId/notes/$noteId", null, $accessToken);
check('DELETE note succeeds (HTTP 200)', $deleteNoteStatus === 200, "got HTTP $deleteNoteStatus");
check('DELETE note actually removes it', count(array_filter($afterNoteDelete['notes'], fn ($n) => $n['note_id'] === $noteId)) === 0);

[$deleteNoteAgainStatus, ] = net_http_json('DELETE', "$baseUrl/scan-sessions/$sessionId/notes/$noteId", null, $accessToken);
check('DELETE note a second time is a clean 404', $deleteNoteAgainStatus === 404, "got HTTP $deleteNoteAgainStatus");

[$updateDeletedNoteStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes/$noteId", ['text' => 'x'], $accessToken);
check('UPDATE a just-deleted note_id is a clean 404, not a crash', $updateDeletedNoteStatus === 404, "got HTTP $updateDeletedNoteStatus");
echo "\n";

echo "== #21 inspection purpose tags ==\n";

[$addPhotoWithTagsStatus, $afterPhotoWithTags] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/photos", ['url' => 'https://example.com/crud-tagged.jpg', 'tags' => ['damage', 'safety_issue']], $accessToken);
check('CREATE photo with tags succeeds (HTTP 200/201)', in_array($addPhotoWithTagsStatus, [200, 201], true), "got HTTP $addPhotoWithTagsStatus");
check('CREATE photo carries the given tags', ($afterPhotoWithTags['photos'][0]['tags'] ?? null) === ['damage', 'safety_issue']);

[$addPhotoNoTagsStatus, $afterPhotoNoTags] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/photos", ['url' => 'https://example.com/crud-untagged.jpg'], $accessToken);
check('CREATE photo with no tags field defaults to an empty array, not omitted or null', in_array($addPhotoNoTagsStatus, [200, 201], true) && array_key_exists('tags', $afterPhotoNoTags['photos'][1] ?? []) && $afterPhotoNoTags['photos'][1]['tags'] === []);

[$addPhotoBadTagStatus, $addPhotoBadTagBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/photos", ['url' => 'https://example.com/crud-badtag.jpg', 'tags' => ['not_a_real_tag']], $accessToken);
check('CREATE photo with an unknown tag value is rejected (HTTP 422)', $addPhotoBadTagStatus === 422, "got HTTP $addPhotoBadTagStatus");
check('the rejection names the specific error', ($addPhotoBadTagBody['error'] ?? null) === 'invalid_tags', 'got ' . ($addPhotoBadTagBody['error'] ?? 'null'));

[$addNoteWithTagsStatus, $afterNoteWithTags] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes", ['text' => 'tagged note', 'tags' => ['confirmed_present']], $accessToken);
check('CREATE note with tags succeeds (HTTP 200/201)', in_array($addNoteWithTagsStatus, [200, 201], true), "got HTTP $addNoteWithTagsStatus");
$taggedNoteId = $afterNoteWithTags['notes'][count($afterNoteWithTags['notes']) - 1]['note_id'];
check('CREATE note carries the given tags', end($afterNoteWithTags['notes'])['tags'] === ['confirmed_present']);

[$updateNoteTagsStatus, $afterNoteTagsUpdate] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes/$taggedNoteId", ['text' => 'tagged note', 'tags' => ['damage', 'maintenance_needed']], $accessToken);
check('UPDATE note tags succeeds (HTTP 200)', $updateNoteTagsStatus === 200, "got HTTP $updateNoteTagsStatus");
$updatedTaggedNote = null;
foreach ($afterNoteTagsUpdate['notes'] as $n) {
    if ($n['note_id'] === $taggedNoteId) {
        $updatedTaggedNote = $n;
    }
}
check('UPDATE note replaces tags in place', $updatedTaggedNote !== null && $updatedTaggedNote['tags'] === ['damage', 'maintenance_needed']);

[$updateNoteNoTagsStatus, $afterNoteNoTagsUpdate] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes/$taggedNoteId", ['text' => 'tagged note edited again'], $accessToken);
check('UPDATE note with no tags field in the body succeeds (HTTP 200)', $updateNoteNoTagsStatus === 200, "got HTTP $updateNoteNoTagsStatus");
$untouchedTaggedNote = null;
foreach ($afterNoteNoTagsUpdate['notes'] as $n) {
    if ($n['note_id'] === $taggedNoteId) {
        $untouchedTaggedNote = $n;
    }
}
check('UPDATE note with no tags field leaves existing tags untouched', $untouchedTaggedNote !== null && $untouchedTaggedNote['tags'] === ['damage', 'maintenance_needed']);

[$updateNoteBadTagStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes/$taggedNoteId", ['text' => 'x', 'tags' => ['nope']], $accessToken);
check('UPDATE note with an unknown tag value is rejected (HTTP 422)', $updateNoteBadTagStatus === 422, "got HTTP $updateNoteBadTagStatus");
echo "\n";

echo count($failures) . " failure(s) out of $checks check(s).\n";
if ($failures !== []) {
    fwrite(STDERR, "\nTEST VERDICT: RED\n");
    foreach ($failures as $f) {
        fwrite(STDERR, " - $f\n");
    }
    exit(1);
}

echo "\nTEST VERDICT: GREEN\n";
exit(0);