<?php

declare(strict_types=1);

require_once __DIR__ . '/lib/http_client.php';

$baseUrl = $argv[1] ?? 'http://127.0.0.1:8089';
$adminApiKey = $argv[2] ?? 'net-test-admin-key';
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

echo "== Sessions can be looked up by property/unit/organisation with the admin key ==\n";

$suffix = substr(md5((string) microtime(true)), 0, 8);
[, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => "prop-net-tier4-$suffix", 'unit_id' => "unit-net-tier4-$suffix", 'organisation_id' => "org-net-tier4-$suffix",
    'purpose' => 'listing', 'occupied' => false,
]);
$sessionId = $session['id'];
$accessToken = $session['access_token'];

[$noKeyStatus, ] = net_http_json_ex('GET', "$baseUrl/scan-sessions?property_id=prop-net-tier4-$suffix", null, null, []);
check('lookup with no admin key is rejected (HTTP 401)', $noKeyStatus === 401, "got HTTP $noKeyStatus");

[$wrongKeyStatus, ] = net_http_json_ex('GET', "$baseUrl/scan-sessions?property_id=prop-net-tier4-$suffix", null, null, ['X-Admin-Api-Key' => 'wrong-key']);
check('lookup with a wrong admin key is rejected (HTTP 401)', $wrongKeyStatus === 401, "got HTTP $wrongKeyStatus");

[$noFilterStatus, ] = net_http_json_ex('GET', "$baseUrl/scan-sessions", null, null, ['X-Admin-Api-Key' => $adminApiKey]);
check('lookup with no filter at all is rejected (HTTP 422)', $noFilterStatus === 422, "got HTTP $noFilterStatus");

[$listStatus, $listBody] = net_http_json_ex('GET', "$baseUrl/scan-sessions?property_id=prop-net-tier4-$suffix", null, null, ['X-Admin-Api-Key' => $adminApiKey]);
check('lookup by property_id with the real admin key succeeds (HTTP 200)', $listStatus === 200, "got HTTP $listStatus");
$foundIds = array_column($listBody['sessions'] ?? [], 'id');
check('lookup finds the session just created', in_array($sessionId, $foundIds, true), 'session id not in result set');
$hasToken = false;
foreach ($listBody['sessions'] ?? [] as $row) {
    if (array_key_exists('access_token', $row)) {
        $hasToken = true;
    }
}
check('lookup response never includes access_token', !$hasToken, 'a session row leaked its access_token');

echo "\n== A single attached photo or note can be deleted without touching the rest ==\n";

net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixture], $accessToken);
[, $afterPhoto1] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/photos", ['url' => 'https://example.com/a.jpg', 'caption' => 'first'], $accessToken);
[, $afterPhoto2] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/photos", ['url' => 'https://example.com/b.jpg', 'caption' => 'second'], $accessToken);
$photoIdToDelete = $afterPhoto1['photos'][0]['photo_id'];

[$deletePhotoStatus, $afterPhotoDelete] = net_http_json('DELETE', "$baseUrl/scan-sessions/$sessionId/photos/$photoIdToDelete", null, $accessToken);
check('deleting a photo succeeds (HTTP 200)', $deletePhotoStatus === 200, "got HTTP $deletePhotoStatus");
check('deleted photo is gone', count(array_filter($afterPhotoDelete['photos'], fn ($p) => $p['photo_id'] === $photoIdToDelete)) === 0);
check('the other photo is untouched', count($afterPhotoDelete['photos']) === 1 && $afterPhotoDelete['photos'][0]['caption'] === 'second');

[$deleteAgainStatus, ] = net_http_json('DELETE', "$baseUrl/scan-sessions/$sessionId/photos/$photoIdToDelete", null, $accessToken);
check('deleting the same photo again is a clean 404', $deleteAgainStatus === 404, "got HTTP $deleteAgainStatus");

[, $afterNote1] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes", ['text' => 'first note'], $accessToken);
[, $afterNote2] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes", ['text' => 'second note'], $accessToken);
$noteIdToDelete = $afterNote1['notes'][0]['note_id'];

[$deleteNoteStatus, $afterNoteDelete] = net_http_json('DELETE', "$baseUrl/scan-sessions/$sessionId/notes/$noteIdToDelete", null, $accessToken);
check('deleting a note succeeds (HTTP 200)', $deleteNoteStatus === 200, "got HTTP $deleteNoteStatus");
check('deleted note is gone', count(array_filter($afterNoteDelete['notes'], fn ($n) => $n['note_id'] === $noteIdToDelete)) === 0);
check('the other note is untouched', count($afterNoteDelete['notes']) === 1 && $afterNoteDelete['notes'][0]['text'] === 'second note');

echo "\n== Deleting a server-uploaded photo also removes the underlying file, not just the JSON entry ==\n";

$tmpUploadPath = sys_get_temp_dir() . '/net_verify_session_lookup_upload.jpg';
file_put_contents($tmpUploadPath, "\xFF\xD8\xFFnet-test-jpeg-bytes");
[, $uploadBody] = net_http_multipart_upload("$baseUrl/scan-sessions/$sessionId/photo-uploads", $tmpUploadPath, 'image/jpeg', $accessToken);
$uploadedPhotoUrl = $uploadBody['url'];

[, $afterUploadedAttach] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/photos", ['url' => $uploadedPhotoUrl], $accessToken);
$uploadedPhotoId = $afterUploadedAttach['photos'][count($afterUploadedAttach['photos']) - 1]['photo_id'];

[$getUploadedBeforeStatus, ] = net_http_raw('GET', $uploadedPhotoUrl, null, $accessToken);
check('the uploaded photo file is fetchable before delete (HTTP 200)', $getUploadedBeforeStatus === 200, "got HTTP $getUploadedBeforeStatus");

net_http_json('DELETE', "$baseUrl/scan-sessions/$sessionId/photos/$uploadedPhotoId", null, $accessToken);

[$getUploadedAfterStatus, ] = net_http_raw('GET', $uploadedPhotoUrl, null, $accessToken);
check('the uploaded photo file is gone after delete, not just unlisted (HTTP 404)', $getUploadedAfterStatus === 404, "got HTTP $getUploadedAfterStatus");

echo "\n== Adjacent case: two photo entries sharing one uploaded file — deleting one must not break the other ==\n";

$tmpDupUploadPath = sys_get_temp_dir() . '/net_verify_session_lookup_dup_upload.jpg';
file_put_contents($tmpDupUploadPath, "\xFF\xD8\xFFnet-test-dup-jpeg-bytes");
[, $dupUploadBody] = net_http_multipart_upload("$baseUrl/scan-sessions/$sessionId/photo-uploads", $tmpDupUploadPath, 'image/jpeg', $accessToken);
$dupPhotoUrl = $dupUploadBody['url'];

net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/photos", ['url' => $dupPhotoUrl], $accessToken);
[, $afterDupAttach] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/photos", ['url' => $dupPhotoUrl], $accessToken);
$dupPhotos = array_values(array_filter($afterDupAttach['photos'], fn ($p) => $p['url'] === $dupPhotoUrl));
check('two entries were attached pointing at the same uploaded file', count($dupPhotos) === 2, 'got ' . count($dupPhotos) . ' entries');
$dupFirstId = $dupPhotos[0]['photo_id'];
$dupSecondId = $dupPhotos[1]['photo_id'];

net_http_json('DELETE', "$baseUrl/scan-sessions/$sessionId/photos/$dupFirstId", null, $accessToken);
[$dupStillReferencedStatus, ] = net_http_raw('GET', $dupPhotoUrl, null, $accessToken);
check('deleting ONE of two entries sharing a file leaves the file intact for the other (HTTP 200)', $dupStillReferencedStatus === 200, "got HTTP $dupStillReferencedStatus");

net_http_json('DELETE', "$baseUrl/scan-sessions/$sessionId/photos/$dupSecondId", null, $accessToken);
[$dupLastRefGoneStatus, ] = net_http_raw('GET', $dupPhotoUrl, null, $accessToken);
check('deleting the LAST entry referencing that file finally removes it (HTTP 404)', $dupLastRefGoneStatus === 404, "got HTTP $dupLastRefGoneStatus");

echo "\n== Adjacent case: deleting a photo/note on a session with no floor plan yet is a clean 409, not a crash ==\n";

[, $emptySession] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-tier4-empty', 'unit_id' => 'unit-net-tier4-empty', 'organisation_id' => 'org-net-tier4-empty',
    'purpose' => 'listing', 'occupied' => false,
]);
[$emptyDeletePhotoStatus, ] = net_http_json('DELETE', "$baseUrl/scan-sessions/{$emptySession['id']}/photos/whatever", null, $emptySession['access_token']);
check('deleting a photo before any capture is a clean 409', $emptyDeletePhotoStatus === 409, "got HTTP $emptyDeletePhotoStatus");

echo "\n== Detected objects render on both exports without throwing ==\n";

[$pngStatus, $pngContentType, $pngBytes] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.png", null, $accessToken);
check('PNG export with a detected object succeeds (HTTP 200)', $pngStatus === 200, "got HTTP $pngStatus");
check('PNG export has the real PNG content type', $pngContentType === 'image/png', "got $pngContentType");

[$pdfStatus, , $pdfBytes] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.pdf", null, $accessToken);
check('PDF export with a detected object succeeds (HTTP 200)', $pdfStatus === 200, "got HTTP $pdfStatus");
check('PDF text mentions the detected object category', str_contains($pdfBytes, 'detected objects: 1 bed'), 'PDF text did not mention the detected object');

[, $noObjectSession] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-tier4-noobj', 'unit_id' => 'unit-net-tier4-noobj', 'organisation_id' => 'org-net-tier4-noobj',
    'purpose' => 'listing', 'occupied' => false,
]);
$noObjectFixture = $fixture;
$noObjectFixture['objects'] = [];
net_http_json('POST', "$baseUrl/scan-sessions/{$noObjectSession['id']}/capture", ['raw_capture' => $noObjectFixture], $noObjectSession['access_token']);
[, , $pngNoObject] = net_http_raw('GET', "$baseUrl/scan-sessions/{$noObjectSession['id']}/export/floorplan.png", null, $noObjectSession['access_token']);
check('a session with a detected object renders different PNG bytes than one without', $pngBytes !== $pngNoObject);

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
