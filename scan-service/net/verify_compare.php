<?php

declare(strict_types=1);

require_once __DIR__ . '/lib/http_client.php';

$baseUrl = $argv[1] ?? 'http://127.0.0.1:8089';
$adminKey = getenv('SCAN_SERVICE_ADMIN_API_KEY') ?: '';
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

function compare_session(string $baseUrl, string $unit, string $purpose, ?string $fixture): array
{
    [, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
        'property_id' => 'prop-net-compare',
        'unit_id' => $unit,
        'organisation_id' => 'org-net-compare',
        'purpose' => $purpose,
        'occupied' => false,
        'floor' => 'Ground',
    ]);
    $id = $session['id'] ?? '';
    $token = $session['access_token'] ?? '';
    if ($fixture !== null) {
        $raw = json_decode((string) file_get_contents(__DIR__ . "/../fixtures/$fixture"), true, 512, JSON_THROW_ON_ERROR);
        [, $plan] = net_http_json('POST', "$baseUrl/scan-sessions/$id/capture", ['raw_capture' => $raw, 'floor' => 'Ground'], $token);
        $roomId = $plan['rooms'][0]['room_id'] ?? '';
        net_http_json('POST', "$baseUrl/scan-sessions/$id/rooms/$roomId/label", ['label' => 'Woonkamer'], $token);
        return [$id, $token, $roomId];
    }
    return [$id, $token, ''];
}

function compare_get(string $baseUrl, string $id, ?string $token, ?string $compareToken, string $query = '', array $extra = []): array
{
    $headers = $extra;
    if ($compareToken !== null) {
        $headers['X-Scan-Compare-Token'] = $compareToken;
    }
    return net_http_json_ex('GET', "$baseUrl/scan-sessions/$id/compare$query", null, $token, $headers);
}

function pdf_get(string $baseUrl, string $id, string $token, string $query, ?string $compareToken): array
{
    $headers = $compareToken !== null ? ['X-Scan-Compare-Token' => $compareToken] : [];
    [$status, , $raw] = net_http_raw_literal('GET', "$baseUrl/scan-sessions/$id/export/floorplan.pdf$query", null, $token, $headers);
    return [$status, $raw];
}

$unit = 'unit-net-compare-' . bin2hex(random_bytes(3));
[$inId, $inToken] = compare_session($baseUrl, $unit, 'check_in', 'roomplan_captured_room_openings_and_objects.json');
[$outId, $outToken, $outRoomId] = compare_session($baseUrl, $unit, 'check_out', 'roomplan_captured_room_lshaped_adversarial.json');
net_http_json('POST', "$baseUrl/scan-sessions/$outId/notes", ['text' => 'Gat in de muur bij het raam', 'room_id' => $outRoomId, 'tags' => ['damage']], $outToken);
net_http_json('POST', "$baseUrl/scan-sessions/$outId/notes", ['text' => 'Sleutels ingeleverd'], $outToken);

echo "== Access needs a token for both scans ==\n";
[$noPathStatus, $noPath] = compare_get($baseUrl, $outId, null, $inToken);
check('no token for this scan is refused', $noPathStatus === 401 && ($noPath['error'] ?? null) === 'invalid_or_missing_access_token', "got HTTP $noPathStatus");
[$noOtherStatus, $noOther] = compare_get($baseUrl, $outId, $outToken, null);
check('no token for the other scan is refused', $noOtherStatus === 401 && ($noOther['error'] ?? null) === 'invalid_or_missing_compare_token', "got HTTP $noOtherStatus");
check('the refusal does not leak the other scan', !str_contains(json_encode($noOther), $inId), json_encode($noOther));
[$wrongStatus] = compare_get($baseUrl, $outId, $outToken, $outToken);
check('the wrong token for the other scan is refused', $wrongStatus === 401, "got HTTP $wrongStatus");
[$unknownStatus, $unknown] = compare_get($baseUrl, $outId, $outToken, $inToken, '?with=00000000-0000-0000-0000-000000000000');
check('an unknown scan id is refused the same way', $unknownStatus === 401 && ($unknown['error'] ?? null) === 'invalid_or_missing_compare_token', "got HTTP $unknownStatus");
[$selfStatus, $self] = compare_get($baseUrl, $outId, $outToken, $outToken, "?with=$outId");
check('a scan cannot be compared with itself', $selfStatus === 422 && ($self['error'] ?? null) === 'compare_with_itself', "got HTTP $selfStatus");

echo "\n== Default pair ==\n";
[$okStatus, $ok] = compare_get($baseUrl, $outId, $outToken, $inToken);
check('check-out compares with the check-in of the same unit', $okStatus === 200 && ($ok['earlier']['id'] ?? null) === $inId && ($ok['later']['id'] ?? null) === $outId, "got HTTP $okStatus " . json_encode($ok['earlier'] ?? null));
[$reverseStatus, $reverse] = compare_get($baseUrl, $inId, $inToken, $outToken);
check('from the check-in side the order is the same', $reverseStatus === 200 && ($reverse['earlier']['id'] ?? null) === $inId && ($reverse['later']['id'] ?? null) === $outId, "got HTTP $reverseStatus");
$room = ($ok['rooms']['changed'][0] ?? null) ?? ($ok['rooms']['unchanged'][0] ?? null);
check('the living room is matched by its name', $room !== null && ($room['matched_by'] ?? null) === 'label_and_floor' && ($room['label'] ?? null) === 'Woonkamer', json_encode($ok['rooms'] ?? null));
check('nothing is reported as removed', ($ok['rooms']['not_matched'] ?? null) === [] && ($ok['rooms']['added'] ?? null) === [], json_encode($ok['rooms'] ?? null));
check('the damage note comes first', ($ok['notes_added'][0]['text'] ?? null) === 'Gat in de muur bij het raam' && count($ok['notes_added'] ?? []) === 2, json_encode($ok['notes_added'] ?? null));
check('objects missing from the check-out are listed', ($ok['objects_gone'] ?? []) !== [], json_encode($ok['objects_gone'] ?? null));
check('the result says indicative', ($ok['measurement_basis'] ?? null) === 'indicative');
[$logStatus, $log] = net_http_json('GET', "$baseUrl/scan-sessions/$inId/access-log", null, $inToken);
$compareLog = array_values(array_filter($log['access_log'] ?? [], static fn (array $e) => ($e['action'] ?? null) === 'compare'));
check('reading the check-in through a compare is in its access log', $logStatus === 200 && in_array('granted', array_column($compareLog, 'outcome'), true) && in_array('denied', array_column($compareLog, 'outcome'), true), json_encode($compareLog));

echo "\n== Thresholds come from the admin settings ==\n";
$changedBefore = count($ok['rooms']['changed'] ?? []);
[$setStatus] = net_http_json_ex('POST', "$baseUrl/admin/settings", ['comparison' => ['area_change_m2' => 20, 'area_change_percent' => 100]], null, ['X-Admin-Api-Key' => $adminKey]);
[, $wide] = compare_get($baseUrl, $outId, $outToken, $inToken);
check('wide thresholds report no changed rooms', $setStatus === 200 && ($wide['rooms']['changed'] ?? null) === [] && ($wide['thresholds']['area_change_m2'] ?? null) == 20, json_encode($wide['thresholds'] ?? null));
net_http_json_ex('POST', "$baseUrl/admin/settings", ['comparison' => ['area_change_m2' => 0.05, 'area_change_percent' => 0.5]], null, ['X-Admin-Api-Key' => $adminKey]);
[, $narrow] = compare_get($baseUrl, $outId, $outToken, $inToken);
check('narrow thresholds report the area change', count($narrow['rooms']['changed'] ?? []) === 1, json_encode($narrow['rooms'] ?? null));
net_http_json_ex('POST', "$baseUrl/admin/settings", ['comparison' => ['area_change_m2' => 0.5, 'area_change_percent' => 5]], null, ['X-Admin-Api-Key' => $adminKey]);
echo "  (default thresholds: $changedBefore changed room(s))\n";

echo "\n== Other scans ==\n";
[$otherUnitId, $otherUnitToken] = compare_session($baseUrl, $unit . '-other', 'check_in', 'roomplan_captured_room_single_room.json');
[$crossStatus, $cross] = compare_get($baseUrl, $outId, $outToken, $otherUnitToken, "?with=$otherUnitId");
check('a scan of another unit is refused even with its token', $crossStatus === 403 && ($cross['error'] ?? null) === 'not_same_unit', "got HTTP $crossStatus");
[$listingId, $listingToken] = compare_session($baseUrl, $unit, 'listing', 'roomplan_captured_room_single_room.json');
[$listingStatus, $listing] = compare_get($baseUrl, $listingId, $listingToken, $inToken);
check('a listing scan has no default pair', $listingStatus === 422 && ($listing['error'] ?? null) === 'compare_needs_with', "got HTTP $listingStatus");
[$withStatus, $with] = compare_get($baseUrl, $listingId, $listingToken, $inToken, "?with=$inId");
check('a listing scan can compare with an explicit scan', $withStatus === 200 && ($with['earlier']['id'] ?? null) === $inId, "got HTTP $withStatus");
[$loneId, $loneToken] = compare_session($baseUrl, $unit . '-lone', 'check_out', 'roomplan_captured_room_single_room.json');
[$loneStatus, $lone] = compare_get($baseUrl, $loneId, $loneToken, $inToken);
check('a check-out without a check-in says there is nothing to compare', $loneStatus === 404 && ($lone['error'] ?? null) === 'no_scan_to_compare', "got HTTP $loneStatus");
[$emptyId, $emptyToken] = compare_session($baseUrl, $unit . '-empty', 'check_in', null);
[$emptyOutId, $emptyOutToken] = compare_session($baseUrl, $unit . '-empty', 'check_out', 'roomplan_captured_room_single_room.json');
[$emptyStatus, $empty] = compare_get($baseUrl, $emptyOutId, $emptyOutToken, $emptyToken);
check('a check-in without rooms cannot be compared yet', $emptyStatus === 404 && ($empty['error'] ?? null) === 'no_floor_plan_yet', "got HTTP $emptyStatus");
[$newerInId, $newerInToken] = compare_session($baseUrl, $unit, 'check_in', 'roomplan_captured_room_single_room.json');
[$staleStatus] = compare_get($baseUrl, $outId, $outToken, $inToken);
check('the default pair moves to the newest check-in', $staleStatus === 401, "got HTTP $staleStatus");
[$newerStatus, $newer] = compare_get($baseUrl, $outId, $outToken, $newerInToken);
check('the newest check-in is used', $newerStatus === 200 && ($newer['later']['id'] ?? null) === $newerInId && ($newer['earlier']['id'] ?? null) === $outId, json_encode([$newer['earlier']['id'] ?? null, $newer['later']['id'] ?? null]));
[$pinnedStatus, $pinned] = compare_get($baseUrl, $outId, $outToken, $inToken, "?with=$inId");
check('an older check-in can still be picked with ?with=', $pinnedStatus === 200 && ($pinned['earlier']['id'] ?? null) === $inId, "got HTTP $pinnedStatus");
[$adminStatus] = compare_get($baseUrl, $outId, null, null, "?with=$inId", ['X-Admin-Api-Key' => $adminKey]);
check('the admin key can compare from the dashboard', $adminStatus === 200, "got HTTP $adminStatus");

echo "\n== PDF ==\n";
[$fullStatus, $fullPdf] = pdf_get($baseUrl, $outId, $outToken, "?style=default&with=$inId", $inToken);
check('the full report of the check-out has a Changes since check-in section', $fullStatus === 200 && str_contains($fullPdf, '(Changes since check-in)'), "got HTTP $fullStatus");
check('the section uses indicative wording', str_contains($fullPdf, 'Indicative: both scans are mobile LiDAR)'));
[$listingPdfStatus, $listingPdf] = pdf_get($baseUrl, $outId, $outToken, "?style=funda&with=$inId", $inToken);
check('the listing plan has no changes section', $listingPdfStatus === 200 && !str_contains($listingPdf, 'Changes since'), "got HTTP $listingPdfStatus");
[$plainStatus, $plainPdf] = pdf_get($baseUrl, $outId, $outToken, '?style=default', null);
check('without a compare token the PDF is unchanged', $plainStatus === 200 && !str_contains($plainPdf, 'Changes since'), "got HTTP $plainStatus");
[$earlierPdfStatus, $earlierPdf] = pdf_get($baseUrl, $inId, $inToken, "?style=default&with=$outId", $outToken);
check('the check-in PDF does not show changes', $earlierPdfStatus === 200 && !str_contains($earlierPdf, 'Changes since'), "got HTTP $earlierPdfStatus");
[$badPdfStatus, $badPdfBody] = pdf_get($baseUrl, $outId, $outToken, "?style=default&with=$inId", 'wrong-token');
check('a PDF with a wrong compare token is refused, not silently plain', $badPdfStatus === 401 && str_contains($badPdfBody, 'invalid_or_missing_compare_token'), "got HTTP $badPdfStatus");

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
