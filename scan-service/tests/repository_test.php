<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';

use VuuroScan\ScanSessionRepository;
use VuuroScan\Storage\Database;

$failures = [];
$checks = 0;

function r_check(string $label, bool $pass, string $detail = ''): void
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

function r_approx(float $a, float $b, float $tol = 2.0): bool
{
    return abs($a - $b) <= $tol;
}

$db = Database::connect(':memory:');
$repo = new ScanSessionRepository($db);

function fresh_session(ScanSessionRepository $repo, int $ttlSeconds = ScanSessionRepository::DEFAULT_TOKEN_TTL_SECONDS): array
{
    return $repo->create('prop-unit-test', 'unit-unit-test', 'org-unit-test', 'listing', false, false, $ttlSeconds);
}

echo "== Token creation sets a real expires_at ==\n";
$defaultSession = fresh_session($repo);
$expectedDefaultExpiry = time() + ScanSessionRepository::DEFAULT_TOKEN_TTL_SECONDS;
r_check(
    'default TTL (90 days) expires_at is ~90 days out, not empty/now',
    r_approx((float) strtotime($defaultSession['expires_at']), (float) $expectedDefaultExpiry, 5.0)
);

$shortSession = fresh_session($repo, 3600);
r_check(
    'a custom 1-hour TTL produces a ~1-hour-out expires_at, not the 90-day default',
    r_approx((float) strtotime($shortSession['expires_at']), (float) (time() + 3600), 5.0)
);
echo "\n";

echo "== Token rotation replaces the token AND the expiry ==\n";
$rotSession = fresh_session($repo);
$oldToken = $rotSession['access_token'];
$oldExpiry = $rotSession['expires_at'];

$rotated = $repo->rotateToken($rotSession['id'], 7200);
r_check('rotateToken() returns a different access_token', $rotated['access_token'] !== $oldToken);
r_check('rotateToken() returns a different expires_at', $rotated['expires_at'] !== $oldExpiry);
r_check(
    'rotated token TTL (2h) is honored, not silently reusing the original TTL',
    r_approx((float) strtotime($rotated['expires_at']), (float) (time() + 7200), 5.0)
);

$refetched = $repo->find($rotSession['id']);
r_check('the OLD token no longer matches after rotation', !$repo->tokenMatches($refetched, $oldToken));
r_check('the NEW token matches after rotation', $repo->tokenMatches($refetched, $rotated['access_token']));
echo "\n";

echo "== isTokenExpired() ==\n";
$futureSession = ['expires_at' => gmdate('c', time() + 3600)];
$pastSession = ['expires_at' => gmdate('c', time() - 3600)];
$noExpirySession = ['expires_at' => ''];

r_check('a future expires_at is NOT expired', $repo->isTokenExpired($futureSession) === false);
r_check('a past expires_at IS expired', $repo->isTokenExpired($pastSession) === true);
r_check(
    'an empty expires_at (pre-migration session) reads as NOT expired, not as expired',
    $repo->isTokenExpired($noExpirySession) === false
);
echo "\n";

echo "== isBeyondRotateGracePeriod() ==\n";
$grace = ScanSessionRepository::ROTATE_GRACE_PERIOD_SECONDS;
$justExpiredSession = ['expires_at' => gmdate('c', time() - 1)];
$withinGraceSession = ['expires_at' => gmdate('c', time() - $grace + 3600)];
$exactlyAtGraceEdgeSession = ['expires_at' => gmdate('c', time() - $grace - 1)];
$wayBeyondGraceSession = ['expires_at' => gmdate('c', time() - $grace - 3600)];
$notYetExpiredSession = ['expires_at' => gmdate('c', time() + 3600)];

r_check('a token that JUST expired is NOT beyond the grace period', $repo->isBeyondRotateGracePeriod($justExpiredSession) === false);
r_check('a token expired well within the grace window is NOT beyond it', $repo->isBeyondRotateGracePeriod($withinGraceSession) === false);
r_check('a token expired just PAST the grace window IS beyond it', $repo->isBeyondRotateGracePeriod($exactlyAtGraceEdgeSession) === true);
r_check('a token expired well past the grace window IS beyond it', $repo->isBeyondRotateGracePeriod($wayBeyondGraceSession) === true);
r_check('a token that has not expired at all is NOT beyond the grace period', $repo->isBeyondRotateGracePeriod($notYetExpiredSession) === false);
r_check('an empty expires_at reads as NOT beyond the grace period', $repo->isBeyondRotateGracePeriod($noExpirySession) === false);
echo "\n";

echo "== findEarlyPurgeCandidates() ==\n";
$oldCheckoutSession = $repo->create('prop-purge-test', 'unit-purge-test', 'org-purge-test', 'check_out', false, false);
$db->prepare("UPDATE scan_sessions SET created_at = :created_at WHERE id = :id")->execute([
    'created_at' => gmdate('c', time() - 40 * 86400),
    'id' => $oldCheckoutSession['id'],
]);
$recentCheckoutSession = $repo->create('prop-purge-test', 'unit-purge-test', 'org-purge-test', 'check_out', false, false);
$oldListingSession = $repo->create('prop-purge-test', 'unit-purge-test', 'org-purge-test', 'listing', false, false);
$db->prepare("UPDATE scan_sessions SET created_at = :created_at WHERE id = :id")->execute([
    'created_at' => gmdate('c', time() - 40 * 86400),
    'id' => $oldListingSession['id'],
]);

$checkoutCandidates = $repo->findEarlyPurgeCandidates('check_out', 30);
r_check('a check_out session older than the retention window is a purge candidate', in_array($oldCheckoutSession['id'], $checkoutCandidates, true));
r_check('a check_out session within the retention window is NOT a purge candidate', !in_array($recentCheckoutSession['id'], $checkoutCandidates, true));
r_check('an old session of a DIFFERENT purpose is not returned when querying check_out', !in_array($oldListingSession['id'], $checkoutCandidates, true));

$listingCandidates = $repo->findEarlyPurgeCandidates('listing', 30);
r_check('an old listing session is a purge candidate when queried under its own purpose', in_array($oldListingSession['id'], $listingCandidates, true));
echo "\n";

echo "== Idempotency key storage ==\n";
$idemSession = fresh_session($repo);
$otherSession = fresh_session($repo);

r_check(
    'no stored response for a key that has never been recorded',
    $repo->findIdempotentResponse($idemSession['id'], 'key-a') === null
);

r_check('claiming a never-seen key succeeds', $repo->claimIdempotencyKey($idemSession['id'], 'key-a', 'fp-a') === true);
r_check(
    'a claimed-but-not-yet-completed key still returns null, not a stale/empty response',
    $repo->findIdempotentResponse($idemSession['id'], 'key-a') === null
);

$repo->completeIdempotencyKey($idemSession['id'], 'key-a', ['rooms' => ['room-1']]);
$stored = $repo->findIdempotentResponse($idemSession['id'], 'key-a');
r_check('a completed claim is returned verbatim for the same (session, key)', $stored === ['rooms' => ['room-1']]);

r_check(
    'a different idempotency key on the same session is NOT treated as a match',
    $repo->findIdempotentResponse($idemSession['id'], 'key-b') === null
);

r_check(
    'the same idempotency key on a DIFFERENT session is NOT treated as a match',
    $repo->findIdempotentResponse($otherSession['id'], 'key-a') === null
);

r_check('re-claiming an already-completed key returns false, not true', $repo->claimIdempotencyKey($idemSession['id'], 'key-a', 'fp-a') === false);
$stillOriginal = $repo->findIdempotentResponse($idemSession['id'], 'key-a');
r_check(
    'a failed re-claim does not disturb the already-completed response',
    $stillOriginal === ['rooms' => ['room-1']]
);
echo "\n";

echo "== Idempotency fingerprint mismatch detection ==\n";
r_check(
    'fingerprint for a never-seen key is null (caller may claim freely)',
    $repo->idempotencyKeyFingerprint($idemSession['id'], 'never-seen-key') === null
);
r_check(
    'fingerprint for a completed key matches what it was claimed with',
    $repo->idempotencyKeyFingerprint($idemSession['id'], 'key-a') === 'fp-a'
);

$pendingSession = fresh_session($repo);
$repo->claimIdempotencyKey($pendingSession['id'], 'pending-key', 'fp-pending');
r_check(
    'fingerprint is visible even while the key is still pending (not completed yet) — this is what lets a colliding reuse be rejected without a poll',
    $repo->idempotencyKeyFingerprint($pendingSession['id'], 'pending-key') === 'fp-pending'
);
echo "\n";

echo "== The race: only one concurrent claim for the same key can win ==\n";
$raceSession = fresh_session($repo);
$firstClaim = $repo->claimIdempotencyKey($raceSession['id'], 'race-key', 'fp-race');
$secondClaim = $repo->claimIdempotencyKey($raceSession['id'], 'race-key', 'fp-race');
r_check('the first claim for a fresh key wins (returns true)', $firstClaim === true);
r_check(
    'a second, concurrent claim for the SAME key loses (returns false) — this is what prevents a double-append',
    $secondClaim === false
);
echo "\n";

echo "== Rate-limit event counting ==\n";
r_check('an unused bucket starts at 0 events', $repo->countRecentEvents('bucket-a', 600) === 0);

$repo->recordEvent('bucket-a');
$repo->recordEvent('bucket-a');
r_check('two recorded events count as 2 within the window', $repo->countRecentEvents('bucket-a', 600) === 2);

r_check('a different, unused bucket is unaffected by bucket-a\'s events', $repo->countRecentEvents('bucket-b', 600) === 0);

$db->exec("INSERT INTO rate_limit_events (bucket, occurred_at) VALUES ('bucket-a', '" . gmdate('c', time() - 3600) . "')");
r_check(
    'an event from an hour ago does NOT count within a 10-minute (600s) window',
    $repo->countRecentEvents('bucket-a', 600) === 2
);
r_check(
    'the same old event DOES count within a window wide enough to include it',
    $repo->countRecentEvents('bucket-a', 7200) === 3
);
echo "\n";

echo "== Rate-limit events are pruned periodically, without disturbing live windows ==\n";
$db->exec("INSERT INTO rate_limit_events (bucket, occurred_at) VALUES ('prune-test-old', '" . gmdate('c', time() - ScanSessionRepository::RATE_LIMIT_EVENT_RETENTION_SECONDS - 60) . "')");
$db->exec("INSERT INTO rate_limit_events (bucket, occurred_at) VALUES ('prune-test-recent', '" . gmdate('c') . "')");

$currentMaxId = (int) $db->query('SELECT COALESCE(MAX(id), 0) FROM rate_limit_events')->fetchColumn();
$callsToNextMultipleOf100 = 100 - ($currentMaxId % 100);
for ($i = 0; $i < $callsToNextMultipleOf100; $i++) {
    $repo->recordEvent('prune-test-filler');
}
$newMaxId = (int) $db->query('SELECT COALESCE(MAX(id), 0) FROM rate_limit_events')->fetchColumn();
r_check('enough events were recorded to cross a multiple of 100 (prune trigger)', $newMaxId % 100 === 0, "max id is $newMaxId");

$oldStmt = $db->prepare("SELECT COUNT(*) FROM rate_limit_events WHERE bucket = 'prune-test-old'");
$oldStmt->execute();
r_check('a row older than RATE_LIMIT_EVENT_RETENTION_SECONDS is pruned away', (int) $oldStmt->fetchColumn() === 0);

$recentStmt = $db->prepare("SELECT COUNT(*) FROM rate_limit_events WHERE bucket = 'prune-test-recent'");
$recentStmt->execute();
r_check('a recent row is NOT pruned', (int) $recentStmt->fetchColumn() === 1);

r_check(
    'pruning older buckets does not disturb an unrelated live window still being counted (bucket-a)',
    $repo->countRecentEvents('bucket-a', 600) === 2
);
echo "\n";

echo "== room_id validation on appendPhoto/appendNote ==\n";
$roomIdSession = fresh_session($repo);
$repo->appendCapture($roomIdSession['id'], [
    'scan_session_id' => $roomIdSession['id'],
    'property_id' => 'p', 'unit_id' => 'u', 'organisation_id' => 'o',
    'capture_provider' => 'test', 'captured_at' => gmdate('c'),
    'measurement_basis' => 'indicative_nen2580_inspired', 'purpose' => 'listing',
    'rooms' => [[
        'room_id' => 'room-real-1', 'label' => 'Room 1', 'floor_area_m2' => 10.0,
        'perimeter_m' => 12.0, 'bounding_dimensions_m' => ['width_m' => 3, 'length_m' => 3],
        'confidence' => 'high', 'outline_m' => [[0, 0], [3, 0], [3, 3], [0, 3]],
        'coverage' => ['score' => 90, 'confidence_counts' => ['high' => 1, 'medium' => 0, 'low' => 0], 'usable' => true, 'message' => null],
    ]],
    'photos' => [], 'notes' => [],
]);

try {
    $repo->appendNote($roomIdSession['id'], ['note_id' => 'n1', 'text' => 'x', 'room_id' => 'room-does-not-exist', 'created_at' => gmdate('c')]);
    r_check('appendNote() rejects a room_id that matches no real room', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    r_check('appendNote() rejects a room_id that matches no real room', true);
}

try {
    $repo->appendPhoto($roomIdSession['id'], ['photo_id' => 'p1', 'url' => 'https://example.invalid/x.jpg', 'room_id' => 'room-does-not-exist', 'taken_at' => gmdate('c')]);
    r_check('appendPhoto() rejects a room_id that matches no real room', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    r_check('appendPhoto() rejects a room_id that matches no real room', true);
}

$withRealRoomId = $repo->appendNote($roomIdSession['id'], ['note_id' => 'n2', 'text' => 'x', 'room_id' => 'room-real-1', 'created_at' => gmdate('c')]);
r_check('appendNote() accepts a room_id that DOES match a real room', count($withRealRoomId['notes']) === 1);

$withNullRoomId = $repo->appendNote($roomIdSession['id'], ['note_id' => 'n3', 'text' => 'x', 'room_id' => null, 'created_at' => gmdate('c')]);
r_check('appendNote() still accepts room_id: null (session-wide note) — this fix must not make room_id required', count($withNullRoomId['notes']) === 2);
echo "\n";

echo "== updateNote(): in-place edit for the per-room auto-saving note field ==\n";
$afterUpdate = $repo->updateNote($roomIdSession['id'], 'n2', 'edited text');
$updatedNote = null;
foreach ($afterUpdate['notes'] as $note) {
    if ($note['note_id'] === 'n2') {
        $updatedNote = $note;
    }
}
r_check('updateNote() changes the matching note\'s text', $updatedNote !== null && $updatedNote['text'] === 'edited text');
r_check('updateNote() does not touch other notes', count($afterUpdate['notes']) === 2);
r_check('updateNote() stamps updated_at', isset($updatedNote['updated_at']));

try {
    $repo->updateNote($roomIdSession['id'], 'note-does-not-exist', 'x');
    r_check('updateNote() rejects an unknown note_id', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    r_check('updateNote() rejects an unknown note_id', true);
}
echo "\n";

echo "== updateNote(): #21 inspection tags ride along with the same edit endpoint ==\n";
$withTagUpdate = $repo->updateNote($roomIdSession['id'], 'n2', 'edited text again', ['damage', 'safety_issue']);
$taggedNote = null;
foreach ($withTagUpdate['notes'] as $note) {
    if ($note['note_id'] === 'n2') {
        $taggedNote = $note;
    }
}
r_check('updateNote() with tags sets them on the matching note', $taggedNote !== null && $taggedNote['tags'] === ['damage', 'safety_issue']);

$withoutTagUpdate = $repo->updateNote($roomIdSession['id'], 'n2', 'edited text a third time');
$untouchedTagsNote = null;
foreach ($withoutTagUpdate['notes'] as $note) {
    if ($note['note_id'] === 'n2') {
        $untouchedTagsNote = $note;
    }
}
r_check('updateNote() called with no tags argument leaves the existing tags untouched', $untouchedTagsNote !== null && $untouchedTagsNote['tags'] === ['damage', 'safety_issue']);
echo "\n";

echo "== updateRoomType(): post-capture room-type correction ==\n";
$afterCorrection = $repo->updateRoomType($roomIdSession['id'], 'room-real-1', 'kitchen');
r_check('updateRoomType() sets confirmed on the matching room', $afterCorrection['rooms'][0]['room_type']['confirmed'] === 'kitchen');

$afterClear = $repo->updateRoomType($roomIdSession['id'], 'room-real-1', null);
r_check('updateRoomType() can clear a previously-set confirmation back to null', $afterClear['rooms'][0]['room_type']['confirmed'] === null);

try {
    $repo->updateRoomType($roomIdSession['id'], 'room-does-not-exist', 'bedroom');
    r_check('updateRoomType() rejects a room_id that matches no real room', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    r_check('updateRoomType() rejects a room_id that matches no real room', true);
}

$noFloorPlanSession = fresh_session($repo);
try {
    $repo->updateRoomType($noFloorPlanSession['id'], 'any-room', 'bedroom');
    r_check('updateRoomType() rejects a session with no captured FloorPlan yet', false, 'no exception was thrown');
} catch (\RuntimeException) {
    r_check('updateRoomType() rejects a session with no captured FloorPlan yet', true);
}

$noGuessSession = fresh_session($repo);
$repo->appendCapture($noGuessSession['id'], [
    'scan_session_id' => $noGuessSession['id'],
    'property_id' => 'p', 'unit_id' => 'u', 'organisation_id' => 'o',
    'capture_provider' => 'test', 'captured_at' => gmdate('c'),
    'measurement_basis' => 'indicative_nen2580_inspired', 'purpose' => 'listing',
    'rooms' => [[
        'room_id' => 'room-no-guess', 'label' => 'Room 1', 'floor_area_m2' => 10.0,
        'perimeter_m' => 12.0, 'bounding_dimensions_m' => ['width_m' => 3, 'length_m' => 3],
        'confidence' => 'high', 'outline_m' => [[0, 0], [3, 0], [3, 3], [0, 3]],
        'coverage' => ['score' => 90, 'confidence_counts' => ['high' => 1, 'medium' => 0, 'low' => 0], 'usable' => true, 'message' => null],
    ]],
    'photos' => [], 'notes' => [],
]);
$afterNoGuessConfirm = $repo->updateRoomType($noGuessSession['id'], 'room-no-guess', 'kitchen');
r_check(
    'updateRoomType() on a room with no prior guess does not fabricate guess/guess_source as JSON null',
    !array_key_exists('guess', $afterNoGuessConfirm['rooms'][0]['room_type'])
        && !array_key_exists('guess_source', $afterNoGuessConfirm['rooms'][0]['room_type'])
);
r_check(
    'that same call still sets confirmed correctly',
    $afterNoGuessConfirm['rooms'][0]['room_type']['confirmed'] === 'kitchen'
);

$afterCustomType = $repo->updateRoomType($roomIdSession['id'], 'room-real-1', 'Home office');
r_check(
    'updateRoomType() accepts a free-text custom value (not just the fixed whitelist)',
    $afterCustomType['rooms'][0]['room_type']['confirmed'] === 'Home office'
);
echo "\n";

echo "== updateRoomLabel(): renaming a captured room ==\n";
$afterRename = $repo->updateRoomLabel($roomIdSession['id'], 'room-real-1', 'Master bedroom');
r_check('updateRoomLabel() sets the label on the matching room', $afterRename['rooms'][0]['label'] === 'Master bedroom');

try {
    $repo->updateRoomLabel($roomIdSession['id'], 'room-does-not-exist', 'x');
    r_check('updateRoomLabel() rejects a room_id that matches no real room', false, 'no exception was thrown');
} catch (\InvalidArgumentException) {
    r_check('updateRoomLabel() rejects a room_id that matches no real room', true);
}

try {
    $repo->updateRoomLabel($noFloorPlanSession['id'], 'any-room', 'x');
    r_check('updateRoomLabel() rejects a session with no captured FloorPlan yet', false, 'no exception was thrown');
} catch (\RuntimeException) {
    r_check('updateRoomLabel() rejects a session with no captured FloorPlan yet', true);
}
echo "\n";

echo "== capture_location: session-wide, set once, never nulled back out ==\n";
function build_capture_for_location(string $sessionId, ?array $location): array
{
    return [
        'scan_session_id' => $sessionId,
        'property_id' => 'p', 'unit_id' => 'u', 'organisation_id' => 'o',
        'capture_provider' => 'test', 'captured_at' => gmdate('c'),
        'measurement_basis' => 'indicative_nen2580_inspired', 'purpose' => 'listing',
        'rooms' => [[
            'room_id' => 'room-loc-1', 'label' => 'Room 1', 'floor_area_m2' => 10.0,
            'perimeter_m' => 12.0, 'bounding_dimensions_m' => ['width_m' => 3, 'length_m' => 3],
            'confidence' => 'high', 'outline_m' => [[0, 0], [3, 0], [3, 3], [0, 3]],
            'coverage' => ['score' => 90, 'confidence_counts' => ['high' => 1, 'medium' => 0, 'low' => 0], 'usable' => true, 'message' => null],
        ]],
        'photos' => [], 'notes' => [],
        'capture_location' => $location,
    ];
}

$locSession = fresh_session($repo);
$afterFirstLoc = $repo->appendCapture($locSession['id'], build_capture_for_location($locSession['id'], ['lat' => 52.09, 'lon' => 5.12, 'accuracy_m' => 8.5, 'captured_at' => gmdate('c')]));
r_check('first capture with a location stores it', $afterFirstLoc['capture_location']['lat'] === 52.09);

$afterSecondNoLoc = $repo->appendCapture($locSession['id'], build_capture_for_location($locSession['id'], null));
r_check('a later capture with no location does not null out the session\'s stored location', $afterSecondNoLoc['capture_location']['lat'] === 52.09);

$noLocSession = fresh_session($repo);
$afterFirstNoLoc = $repo->appendCapture($noLocSession['id'], build_capture_for_location($noLocSession['id'], null));
r_check('a session that never got a location stays null, not fabricated', $afterFirstNoLoc['capture_location'] === null);

$afterSecondWithLoc = $repo->appendCapture($noLocSession['id'], build_capture_for_location($noLocSession['id'], ['lat' => 1.0, 'lon' => 2.0, 'accuracy_m' => 5.0, 'captured_at' => gmdate('c')]));
r_check('a later capture CAN fill in a location the first capture missed', $afterSecondWithLoc['capture_location']['lat'] === 1.0);
echo "\n";

echo "== photos/notes are capped per session (MAX_PHOTOS_PER_SESSION / MAX_NOTES_PER_SESSION) ==\n";
$capSession = fresh_session($repo);
$repo->appendCapture($capSession['id'], [
    'scan_session_id' => $capSession['id'],
    'property_id' => 'p', 'unit_id' => 'u', 'organisation_id' => 'o',
    'capture_provider' => 'test', 'captured_at' => gmdate('c'),
    'measurement_basis' => 'indicative_nen2580_inspired', 'purpose' => 'listing',
    'rooms' => [[
        'room_id' => 'room-cap-1', 'label' => 'Room 1', 'floor_area_m2' => 10.0,
        'perimeter_m' => 12.0, 'bounding_dimensions_m' => ['width_m' => 3, 'length_m' => 3],
        'confidence' => 'high', 'outline_m' => [[0, 0], [3, 0], [3, 3], [0, 3]],
        'coverage' => ['score' => 90, 'confidence_counts' => ['high' => 1, 'medium' => 0, 'low' => 0], 'usable' => true, 'message' => null],
    ]],
    'photos' => [], 'notes' => [],
]);

for ($i = 0; $i < ScanSessionRepository::MAX_NOTES_PER_SESSION; $i++) {
    $result = $repo->appendNote($capSession['id'], ['note_id' => "cap-note-$i", 'text' => 'x', 'room_id' => null, 'created_at' => gmdate('c')]);
}
r_check(
    "exactly MAX_NOTES_PER_SESSION (" . ScanSessionRepository::MAX_NOTES_PER_SESSION . ') notes attach without error',
    count($result['notes']) === ScanSessionRepository::MAX_NOTES_PER_SESSION
);
try {
    $repo->appendNote($capSession['id'], ['note_id' => 'cap-note-over', 'text' => 'x', 'room_id' => null, 'created_at' => gmdate('c')]);
    r_check('the note ONE PAST the cap is rejected', false, 'no exception was thrown');
} catch (\OverflowException) {
    r_check('the note ONE PAST the cap is rejected', true);
}

for ($i = 0; $i < ScanSessionRepository::MAX_PHOTOS_PER_SESSION; $i++) {
    $result = $repo->appendPhoto($capSession['id'], ['photo_id' => "cap-photo-$i", 'url' => 'https://example.invalid/x.jpg', 'caption' => '', 'room_id' => null, 'taken_at' => gmdate('c')]);
}
r_check(
    "exactly MAX_PHOTOS_PER_SESSION (" . ScanSessionRepository::MAX_PHOTOS_PER_SESSION . ') photos attach without error',
    count($result['photos']) === ScanSessionRepository::MAX_PHOTOS_PER_SESSION
);
try {
    $repo->appendPhoto($capSession['id'], ['photo_id' => 'cap-photo-over', 'url' => 'https://example.invalid/x.jpg', 'caption' => '', 'room_id' => null, 'taken_at' => gmdate('c')]);
    r_check('the photo ONE PAST the cap is rejected (independent budget, not shared with notes)', false, 'no exception was thrown');
} catch (\OverflowException) {
    r_check('the photo ONE PAST the cap is rejected (independent budget, not shared with notes)', true);
}
echo "\n";

echo "== rooms are capped per session across appendCapture() calls (MAX_ROOMS_PER_SESSION) ==\n";
$roomCapSession = fresh_session($repo);
$roomCapFloorPlan = null;
for ($i = 0; $i < ScanSessionRepository::MAX_ROOMS_PER_SESSION; $i++) {
    $roomCapFloorPlan = $repo->appendCapture($roomCapSession['id'], [
        'scan_session_id' => $roomCapSession['id'],
        'property_id' => 'p', 'unit_id' => 'u', 'organisation_id' => 'o',
        'capture_provider' => 'test', 'captured_at' => gmdate('c'),
        'measurement_basis' => 'indicative_nen2580_inspired', 'purpose' => 'listing',
        'rooms' => [[
            'room_id' => "room-cap-$i", 'label' => "Room $i", 'floor_area_m2' => 10.0,
            'perimeter_m' => 12.0, 'bounding_dimensions_m' => ['width_m' => 3, 'length_m' => 3],
            'confidence' => 'high', 'outline_m' => [[0, 0], [3, 0], [3, 3], [0, 3]],
            'coverage' => ['score' => 90, 'confidence_counts' => ['high' => 1, 'medium' => 0, 'low' => 0], 'usable' => true, 'message' => null],
        ]],
        'photos' => [], 'notes' => [],
    ]);
}
r_check(
    "exactly MAX_ROOMS_PER_SESSION (" . ScanSessionRepository::MAX_ROOMS_PER_SESSION . ') rooms accumulate across repeated capture() calls without error',
    count($roomCapFloorPlan['rooms']) === ScanSessionRepository::MAX_ROOMS_PER_SESSION
);
try {
    $repo->appendCapture($roomCapSession['id'], [
        'scan_session_id' => $roomCapSession['id'],
        'property_id' => 'p', 'unit_id' => 'u', 'organisation_id' => 'o',
        'capture_provider' => 'test', 'captured_at' => gmdate('c'),
        'measurement_basis' => 'indicative_nen2580_inspired', 'purpose' => 'listing',
        'rooms' => [[
            'room_id' => 'room-cap-over', 'label' => 'Room over', 'floor_area_m2' => 10.0,
            'perimeter_m' => 12.0, 'bounding_dimensions_m' => ['width_m' => 3, 'length_m' => 3],
            'confidence' => 'high', 'outline_m' => [[0, 0], [3, 0], [3, 3], [0, 3]],
            'coverage' => ['score' => 90, 'confidence_counts' => ['high' => 1, 'medium' => 0, 'low' => 0], 'usable' => true, 'message' => null],
        ]],
        'photos' => [], 'notes' => [],
    ]);
    r_check('the capture call ONE ROOM PAST the cap is rejected with OverflowException, not silently merged', false, 'no exception was thrown');
} catch (\OverflowException) {
    r_check('the capture call ONE ROOM PAST the cap is rejected with OverflowException, not silently merged', true);
}
echo "\n";

echo "== access_log has an index on scan_session_id, not just implicit table order ==\n";
$planStmt = $db->prepare("EXPLAIN QUERY PLAN SELECT action, outcome, occurred_at FROM access_log WHERE scan_session_id = :id ORDER BY id ASC");
$planStmt->execute(['id' => 'irrelevant-for-plan-shape']);
$planDetail = implode(' | ', array_column($planStmt->fetchAll(PDO::FETCH_ASSOC), 'detail'));
r_check(
    "access-log lookup by scan_session_id uses an index (SEARCH), not a full SCAN",
    str_contains($planDetail, 'SEARCH access_log') && str_contains($planDetail, 'idx_access_log_session'),
    "query plan was: $planDetail"
);

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