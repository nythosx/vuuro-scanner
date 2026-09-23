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

function create_session(string $baseUrl, array $extra = []): array
{
    return net_http_json('POST', "$baseUrl/scan-sessions", [
        'property_id' => 'prop-net-floor',
        'unit_id' => 'unit-net-floor',
        'organisation_id' => 'org-net-floor',
        'purpose' => 'listing',
        'occupied' => false,
        ...$extra,
    ]);
}

function room_floors(?array $floorPlan): array
{
    return array_map(static fn (array $room) => $room['floor'] ?? null, $floorPlan['rooms'] ?? []);
}

$fixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);

echo "== Session default floor ==\n";
[$status, $session] = create_session($baseUrl, ['floor' => '  Attic  ']);
check('POST /scan-sessions with a floor returns 201', $status === 201, "got HTTP $status");
check('default_floor is stored trimmed', ($session['default_floor'] ?? null) === 'Attic', 'got ' . var_export($session['default_floor'] ?? null, true));
$sessionId = $session['id'] ?? '';
$token = $session['access_token'] ?? '';

[$noFloorStatus, $noFloorSession] = create_session($baseUrl);
check('a session without a floor gets default_floor ""', $noFloorStatus === 201 && ($noFloorSession['default_floor'] ?? null) === '', 'got ' . var_export($noFloorSession['default_floor'] ?? null, true));

[$longStatus] = create_session($baseUrl, ['floor' => str_repeat('f', 61)]);
check('a 61-character floor is rejected with 422', $longStatus === 422, "got HTTP $longStatus");
[$ctrlStatus] = create_session($baseUrl, ['floor' => "Attic\n"]);
check('a trailing newline is trimmed away and accepted', $ctrlStatus === 201, "got HTTP $ctrlStatus");
[$innerCtrlStatus] = create_session($baseUrl, ['floor' => "At\x01tic"]);
check('a floor with an embedded control character is rejected with 422', $innerCtrlStatus === 422, "got HTTP $innerCtrlStatus");
[$typeStatus] = create_session($baseUrl, ['floor' => 3]);
check('a non-string floor is rejected with 422', $typeStatus === 422, "got HTTP $typeStatus");

echo "\n== Rooms inherit the session floor, or take a per-capture floor ==\n";
[$cap1Status, $plan1] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixture], $token);
check('first capture succeeds', $cap1Status === 200, "got HTTP $cap1Status");
check('a capture without a floor inherits the session default (Attic)', room_floors($plan1) === ['Attic'], json_encode(room_floors($plan1)));

[$setStatus, $setBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/default-floor", ['floor' => '1st floor'], $token);
check('POST .../default-floor returns 200', $setStatus === 200, "got HTTP $setStatus");
check('POST .../default-floor echoes the new floor', ($setBody['default_floor'] ?? null) === '1st floor', json_encode($setBody));
check('POST .../default-floor does not return a token', !array_key_exists('access_token', $setBody ?? []));

[$cap2Status, $plan2] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixture], $token);
check('second capture succeeds', $cap2Status === 200, "got HTTP $cap2Status");
check('the new room takes the updated default (1st floor) and the first room keeps Attic', room_floors($plan2) === ['Attic', '1st floor'], json_encode(room_floors($plan2)));

[$cap3Status, $plan3] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixture, 'floor' => 'Basement'], $token);
check('a per-capture floor overrides the session default', $cap3Status === 200 && room_floors($plan3) === ['Attic', '1st floor', 'Basement'], json_encode(room_floors($plan3)));

[$unauthStatus] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/default-floor", ['floor' => 'Roof']);
check('POST .../default-floor without a token is rejected with 401', $unauthStatus === 401, "got HTTP $unauthStatus");
[$missingStatus] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/default-floor", ['other' => 'x'], $token);
check('POST .../default-floor without a floor field is rejected with 422', $missingStatus === 422, "got HTTP $missingStatus");
[$clearStatus, $clearBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/default-floor", ['floor' => ''], $token);
check('an empty floor clears the default', $clearStatus === 200 && ($clearBody['default_floor'] ?? null) === '', json_encode($clearBody));
[$cap4Status, $plan4] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixture], $token);
check('after clearing, a new room has floor null (never fabricated)', $cap4Status === 200 && array_key_exists(3, room_floors($plan4)) && room_floors($plan4)[3] === null, json_encode(room_floors($plan4)));

echo "\n== Fused replace applies per-capture floors ==\n";
[, $fusedSession] = create_session($baseUrl, ['floor' => '2nd floor']);
net_http_json('POST', "$baseUrl/scan-sessions/{$fusedSession['id']}/capture", ['raw_capture' => $fixture], $fusedSession['access_token']);
[$fusedStatus, $fusedPlan] = net_http_json('POST', "$baseUrl/scan-sessions/{$fusedSession['id']}/rooms", [
    'captures' => [
        ['raw_capture' => $fixture],
        ['raw_capture' => $fixture, 'floor' => 'Attic'],
    ],
], $fusedSession['access_token']);
check('POST .../rooms succeeds', $fusedStatus === 200, "got HTTP $fusedStatus");
check('fused rooms use the per-capture floor, else the session default', room_floors($fusedPlan) === ['2nd floor', 'Attic'], json_encode(room_floors($fusedPlan)));

echo "\n== Export style=funda ==\n";
[$svgStatus, , $defaultSvg] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.svg", null, $token);
[$fundaSvgStatus, , $fundaSvg] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.svg?style=funda", null, $token);
check('default and funda SVG both return 200', $svgStatus === 200 && $fundaSvgStatus === 200, "default=$svgStatus funda=$fundaSvgStatus");
$defaultHasDetail = str_contains($defaultSvg, 'id="objects"') || str_contains($defaultSvg, 'stroke-dasharray="6,5"');
check('the default SVG draws furniture or the walk path (so the funda check below is meaningful)', $defaultHasDetail);
check('the funda SVG draws no furniture group', !str_contains($fundaSvg, 'id="objects"'));
check('the funda SVG draws no walk path', !str_contains($fundaSvg, 'stroke-dasharray="6,5"'));
[$pngStatus, $pngType] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.png?style=funda", null, $token);
check('funda PNG returns 200 image/png', $pngStatus === 200 && str_contains($pngType, 'image/png'), "got HTTP $pngStatus $pngType");
[$fundaPdfStatus, $fundaPdfType, $fundaPdf] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.pdf?style=funda", null, $token);
check('funda PDF returns 200 application/pdf', $fundaPdfStatus === 200 && str_contains($fundaPdfType, 'application/pdf') && str_starts_with($fundaPdf, '%PDF-'), "got HTTP $fundaPdfStatus $fundaPdfType");
[$badStyleStatus] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.png?style=bogus", null, $token);
check('an unknown style is rejected with 422', $badStyleStatus === 422, "got HTTP $badStyleStatus");

echo "\n== PDF: missing-item notes, room names, page sizes ==\n";
$firstRoomId = $plan4['rooms'][0]['room_id'] ?? '';
[$noteStatus] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes", [
    'text' => '[Skylight / roof window] diagonal roof window not detected',
    'room_id' => $firstRoomId,
    'tags' => ['missing_item'],
], $token);
check('a note tagged missing_item is accepted', $noteStatus === 201 || $noteStatus === 200, "got HTTP $noteStatus");
[$typeStatus] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms/$firstRoomId/room-type", ['room_type' => 'attic'], $token);
check('confirming the first room as attic succeeds', $typeStatus === 200, "got HTTP $typeStatus");

[$pdfStatus, , $pdf] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.pdf", null, $token);
check('PDF export returns 200', $pdfStatus === 200, "got HTTP $pdfStatus");
check('the missing-item note prints with a "missing item:" prefix', str_contains($pdf, 'missing item: [Skylight / roof window]'));
check('the confirmed room name leads: "Attic (Room 1)"', str_contains($pdf, 'Attic \(Room 1\)'));
check('the old "Room 1 (Attic)" ordering is gone', !str_contains($pdf, 'Room 1 \(Attic\)'));
preg_match_all('#/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)\s*\]#', $pdf, $boxes, PREG_SET_ORDER);
$sizes = array_unique(array_map(static fn (array $b) => $b[1] . 'x' . $b[2], $boxes));
check('the PDF has more than one page', count($boxes) > 1, 'pages=' . count($boxes));
check('every PDF page is the same size', count($sizes) === 1, 'sizes=' . implode(',', $sizes));

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
