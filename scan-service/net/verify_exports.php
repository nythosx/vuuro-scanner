<?php

declare(strict_types=1);

require_once __DIR__ . '/lib/http_client.php';
require_once __DIR__ . '/../tests/lib/pdf_object_graph.php';

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

function check_pdf_graph(string $label, string $pdfBytes): void
{
    $problems = pdf_validate_object_graph($pdfBytes);
    check("$label: object graph is fully valid (parses like a real PDF reader would walk it)", $problems === [], implode('; ', $problems));
}

$fixtureA = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);
$fixtureB = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_lshaped_adversarial.json'), true, 512, JSON_THROW_ON_ERROR);

[, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-exports',
    'unit_id' => 'unit-net-exports',
    'organisation_id' => 'org-net-exports',
    'purpose' => 'listing',
    'occupied' => false,
]);
$sessionId = $session['id'] ?? null;
$accessToken = $session['access_token'] ?? null;
if ($sessionId === null || $accessToken === null) {
    fwrite(STDERR, "Could not create a session/access_token — cannot continue.\n");
    exit(1);
}

[, $afterA] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixtureA], $accessToken);
[, $floorPlan] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixtureB], $accessToken);
check('setup: two-room session captured before testing exports', count($floorPlan['rooms'] ?? []) === 2, 'got ' . count($floorPlan['rooms'] ?? []));

echo "\n== PNG export ==\n";
[$pngStatus, $pngContentType, $pngBytes] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.png", null, $accessToken);
check('PNG export returns HTTP 200', $pngStatus === 200, "got HTTP $pngStatus");
check('PNG export has image/png content type', str_contains($pngContentType, 'image/png'), "got $pngContentType");
check('PNG bytes start with the PNG file signature', substr($pngBytes, 0, 8) === "\x89PNG\r\n\x1a\n", 'signature mismatch — not a valid PNG');

$tmpPath = tempnam(sys_get_temp_dir(), 'net_png_');
file_put_contents($tmpPath, $pngBytes);
$info = @getimagesize($tmpPath);
unlink($tmpPath);
check('PNG decodes as a valid image via getimagesize()', $info !== false, 'getimagesize() failed to parse the bytes');
if ($info !== false) {
    $expectedMinWidth = (int) round(($floorPlan['rooms'][0]['bounding_dimensions_m']['width_m'] + $floorPlan['rooms'][1]['bounding_dimensions_m']['width_m']) * 60);
    check('PNG width scales with combined room widths (not a fixed canvas)', $info[0] >= $expectedMinWidth,
        "PNG width={$info[0]}, expected at least {$expectedMinWidth} for two rooms side by side");
}

echo "\n== PDF export ==\n";
[$pdfStatus, $pdfContentType, $pdfBytes] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.pdf", null, $accessToken);
check('PDF export returns HTTP 200', $pdfStatus === 200, "got HTTP $pdfStatus");
check('PDF export has application/pdf content type', str_contains($pdfContentType, 'application/pdf'), "got $pdfContentType");
check('PDF starts with %PDF- header', str_starts_with($pdfBytes, '%PDF-'));
check('PDF ends with %%EOF', str_ends_with(rtrim($pdfBytes), '%%EOF'));

preg_match('/startxref\s+(\d+)\s+%%EOF/', $pdfBytes, $xrefMatch);
$xrefOffsetValid = isset($xrefMatch[1]) && substr($pdfBytes, (int) $xrefMatch[1], 4) === 'xref';
check('startxref points exactly at the "xref" keyword', $xrefOffsetValid);

preg_match_all('/^(\d{10}) 00000 n \s*$/m', $pdfBytes, $objMatches);
$allObjectOffsetsValid = true;
foreach ($objMatches[1] as $i => $offsetStr) {
    $objNum = $i + 1;
    $offset = (int) $offsetStr;
    if (substr($pdfBytes, $offset, strlen("$objNum 0 obj")) !== "$objNum 0 obj") {
        $allObjectOffsetsValid = false;
        break;
    }
}
check('every xref-declared object offset points at the correct "N 0 obj" header',
    $allObjectOffsetsValid && count($objMatches[1]) > 0);

$room1Label = $floorPlan['rooms'][0]['label'];
$room2Area = number_format((float) $floorPlan['rooms'][1]['floor_area_m2'], 2, '.', '');
check("PDF content contains the first room's label ($room1Label)", str_contains($pdfBytes, $room1Label));
check("PDF content contains the second room's area ($room2Area)", str_contains($pdfBytes, $room2Area));
check_pdf_graph('two-room PDF (embeds the floor plan drawing image)', $pdfBytes);

echo "\n== SVG export ==\n";
[$svgStatus, $svgContentType, $svgBytes] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.svg", null, $accessToken);
check('SVG export returns HTTP 200', $svgStatus === 200, "got HTTP $svgStatus");
check('SVG export has image/svg+xml content type', str_contains($svgContentType, 'image/svg+xml'), "got $svgContentType");
check('SVG bytes start with an <svg root element', str_starts_with($svgBytes, '<svg '));
check("SVG content contains the first room's label ($room1Label)", str_contains($svgBytes, $room1Label));
check('SVG content contains the second room\'s label', str_contains($svgBytes, $floorPlan['rooms'][1]['label']));

[$svgNoAuthStatus, ] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.svg");
check('SVG export without an access token is rejected with HTTP 401', $svgNoAuthStatus === 401, "got HTTP $svgNoAuthStatus");

[$svgBadLayoutStatus, $svgBadLayoutBody] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.svg?layout=bogus", null, $accessToken);
check('SVG export rejects an invalid layout value as invalid_layout', $svgBadLayoutStatus === 422 && ($svgBadLayoutBody['error'] ?? null) === 'invalid_layout', "got HTTP $svgBadLayoutStatus: " . json_encode($svgBadLayoutBody));

[$svgTilesStatus, , $svgTilesBytes] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.svg?layout=tiles", null, $accessToken);
check('SVG export accepts layout=tiles', $svgTilesStatus === 200, "got HTTP $svgTilesStatus");
check('layout=tiles SVG still contains both room labels', str_contains($svgTilesBytes, $room1Label) && str_contains($svgTilesBytes, $floorPlan['rooms'][1]['label']));

echo "\n== Adversarial: a fused layout spread far beyond the render-size sanity bound is rejected, not silently oversized ==\n";
[, $hugeFusedSession] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-exports-huge-fused',
    'unit_id' => 'unit-net-exports-huge-fused',
    'organisation_id' => 'org-net-exports-huge-fused',
    'purpose' => 'listing',
    'occupied' => false,
]);
$hugeFusedSessionId = $hugeFusedSession['id'] ?? null;
$hugeFusedToken = $hugeFusedSession['access_token'] ?? null;
if ($hugeFusedSessionId !== null && $hugeFusedToken !== null) {
    for ($i = 0; $i < 10; $i++) {
        $spreadCapture = $fixtureA;
        $spreadCapture['structure_origin_m'] = [$i * 10.0, 0.0];
        [$spreadStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$hugeFusedSessionId/capture", ['raw_capture' => $spreadCapture], $hugeFusedToken);
        check("setup: fused room $i (10m apart, real captured structure_origin_m) accepted", $spreadStatus === 200, "got HTTP $spreadStatus");
    }

    [$hugePngStatus, , $hugePngBytes] = net_http_raw('GET', "$baseUrl/scan-sessions/$hugeFusedSessionId/export/floorplan.png", null, $hugeFusedToken);
    check('PNG export of the same wide-spread fused layout is rejected (not silently oversized), matching the SVG guard below', $hugePngStatus === 422, "got HTTP $hugePngStatus");

    [$hugeSvgStatus, $hugeSvgBody] = net_http_json('GET', "$baseUrl/scan-sessions/$hugeFusedSessionId/export/floorplan.svg", null, $hugeFusedToken);
    check('SVG export of a wide-spread fused layout is rejected as unrenderable_floor_plan, not an unboundedly huge canvas',
        $hugeSvgStatus === 422 && ($hugeSvgBody['error'] ?? null) === 'unrenderable_floor_plan',
        "got HTTP $hugeSvgStatus: " . json_encode($hugeSvgBody));

    [$hugeTilesStatus, ] = net_http_raw('GET', "$baseUrl/scan-sessions/$hugeFusedSessionId/export/floorplan.svg?layout=tiles", null, $hugeFusedToken);
    check('the same wide-spread rooms still export fine as unfused tiles (layout=tiles sidesteps the fused canvas entirely)', $hugeTilesStatus === 200, "got HTTP $hugeTilesStatus");
}

echo "\n== Adversarial: an attached real photo must embed as a valid image XObject ==\n";
[, $photoSession] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-exports-photo',
    'unit_id' => 'unit-net-exports-photo',
    'organisation_id' => 'org-net-exports-photo',
    'purpose' => 'listing',
    'occupied' => false,
]);
$photoSessionId = $photoSession['id'] ?? null;
$photoSessionToken = $photoSession['access_token'] ?? null;
if ($photoSessionId !== null && $photoSessionToken !== null) {
    net_http_json('POST', "$baseUrl/scan-sessions/$photoSessionId/capture", ['raw_capture' => $fixtureA], $photoSessionToken);

    $realPhotoPath = tempnam(sys_get_temp_dir(), 'net_photo_');
    $img = imagecreatetruecolor(800, 600);
    imagefilledrectangle($img, 0, 0, 800, 600, imagecolorallocate($img, 90, 140, 200));
    imagejpeg($img, $realPhotoPath, 90);
    imagedestroy($img);

    [$photoUploadStatus, $photoUploadBody] = net_http_multipart_upload("$baseUrl/scan-sessions/$photoSessionId/photo-uploads", $realPhotoPath, 'image/jpeg', $photoSessionToken);
    unlink($realPhotoPath);
    check('setup: real photo uploads', $photoUploadStatus === 201, "got HTTP $photoUploadStatus");

    if ($photoUploadStatus === 201) {
        [$photoAttachStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$photoSessionId/photos", ['url' => $photoUploadBody['url'], 'caption' => 'Test photo'], $photoSessionToken);
        check('setup: uploaded photo attaches to the session', $photoAttachStatus === 201, "got HTTP $photoAttachStatus");

        [$photoPdfStatus, , $photoPdfBytes] = net_http_raw('GET', "$baseUrl/scan-sessions/$photoSessionId/export/floorplan.pdf", null, $photoSessionToken);
        check('PDF export with an attached photo returns HTTP 200', $photoPdfStatus === 200, "got HTTP $photoPdfStatus");
        if ($photoPdfStatus === 200) {
            check('PDF with an attached photo has more than one page (floor plan page + photo page)', (bool) preg_match('/\/Count\s+(?!1\b)\d+/', $photoPdfBytes), 'PDF still declares a single page');
            check_pdf_graph('PDF with a real attached photo (two embedded JPEG XObjects)', $photoPdfBytes);
        }
    }
}

echo "\n== Adversarial: many rooms must not go missing off a fixed-size PDF page ==\n";

[, $manyRoomsSession] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-exports-many',
    'unit_id' => 'unit-net-exports-many',
    'organisation_id' => 'org-net-exports-many',
    'purpose' => 'listing',
    'occupied' => false,
]);
$manyRoomsSessionId = $manyRoomsSession['id'] ?? null;
$manyRoomsToken = $manyRoomsSession['access_token'] ?? null;

if ($manyRoomsSessionId !== null && $manyRoomsToken !== null) {
    $manyFloors = [];
    for ($i = 0; $i < 40; $i++) {
        $manyFloors[] = [
            'identifier' => "floor-many-$i",
            'category' => 'floor',
            'confidence' => 'high',
            'polygonCorners' => [[0.0, 0.0, 0.0], [3.0, 0.0, 0.0], [3.0, 0.0, 3.0], [0.0, 0.0, 3.0]],
        ];
    }
    [$manyCaptureStatus, $manyFloorPlan] = net_http_json('POST', "$baseUrl/scan-sessions/$manyRoomsSessionId/capture", ['raw_capture' => ['floors' => $manyFloors]], $manyRoomsToken);
    check('setup: 40-room capture succeeds in one call', $manyCaptureStatus === 200 && count($manyFloorPlan['rooms'] ?? []) === 40, "got HTTP $manyCaptureStatus with " . count($manyFloorPlan['rooms'] ?? []) . ' room(s)');

    [$manyPdfStatus, , $manyPdfBytes] = net_http_raw('GET', "$baseUrl/scan-sessions/$manyRoomsSessionId/export/floorplan.pdf", null, $manyRoomsToken);
    check('40-room PDF export still returns HTTP 200, not a crash', $manyPdfStatus === 200, "got HTTP $manyPdfStatus");

    if ($manyPdfStatus === 200) {
        check('40-room PDF spans more than one page (/Count 4 or higher, never /Count 1)', (bool) preg_match('/\/Count\s+(?!1\b)\d+/', $manyPdfBytes), 'PDF still declares a single page for 40 rooms');

        preg_match_all('/1 0 0 1 [\d.]+ (-?[\d.]+) Tm/', $manyPdfBytes, $tmMatches);
        $offPageYs = array_filter($tmMatches[1] ?? [], static fn ($y) => (float) $y < 0 || (float) $y > 792);
        check(
            'every text line\'s Y position is found at all, and all stay within the 792pt page (none negative/over-tall)',
            $tmMatches[1] !== [] && $offPageYs === [],
            count($tmMatches[1]) . ' Tm operators found, ' . count($offPageYs) . ' positioned off-page: ' . implode(', ', array_slice($offPageYs, 0, 5))
        );

        $missingLabels = [];
        foreach ($manyFloorPlan['rooms'] as $room) {
            if (!str_contains($manyPdfBytes, $room['label'])) {
                $missingLabels[] = $room['label'];
            }
        }
        check('every one of the 40 room labels appears in the PDF, including the last', $missingLabels === [], 'missing: ' . implode(', ', $missingLabels));

        $totalAreaLine = sprintf('%.2f', array_sum(array_column($manyFloorPlan['rooms'], 'floor_area_m2')));
        check('the trailing "Total indicative area" line is still present, not pushed off-page', str_contains($manyPdfBytes, $totalAreaLine));

        preg_match_all('/^(\d{10}) 00000 n \s*$/m', $manyPdfBytes, $manyObjMatches);
        $manyOffsetsValid = count($manyObjMatches[1]) > 0;
        foreach ($manyObjMatches[1] as $i => $offsetStr) {
            $objNum = $i + 1;
            $offset = (int) $offsetStr;
            if (substr($manyPdfBytes, $offset, strlen("$objNum 0 obj")) !== "$objNum 0 obj") {
                $manyOffsetsValid = false;
                break;
            }
        }
        check('the paginated 40-room PDF still has a structurally valid xref table', $manyOffsetsValid);
        check_pdf_graph('paginated 40-room PDF', $manyPdfBytes);
    }

    [$manyPngStatus, $manyPngBody] = net_http_json('GET', "$baseUrl/scan-sessions/$manyRoomsSessionId/export/floorplan.png", null, $manyRoomsToken);
    check(
        'a 40-room PNG export that would exceed the canvas size bound returns a clean 422, not a 500 or a truncated image',
        $manyPngStatus === 422,
        "got HTTP $manyPngStatus"
    );
    check(
        'the 422 uses the unrenderable_floor_plan error code, same as the PDF/MAX_PAGES case',
        ($manyPngBody['error'] ?? null) === 'unrenderable_floor_plan',
        'got ' . json_encode($manyPngBody)
    );
}

echo "\n== Adversarial: non-ASCII property/unit/org identity through the real PDF export ==\n";
[, $unicodeSession] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-café-日本-☂',
    'unit_id' => 'unit-Straße-1',
    'organisation_id' => 'org-Müller',
    'purpose' => 'listing',
    'occupied' => false,
]);
$unicodeSessionId = $unicodeSession['id'] ?? null;
$unicodeSessionToken = $unicodeSession['access_token'] ?? null;
if ($unicodeSessionId === null || $unicodeSessionToken === null) {
    check('setup: session with non-ASCII identity fields can be created at all', false, 'session creation itself rejected non-ASCII input — unexpected');
} else {
    check('setup: session with non-ASCII identity fields can be created at all', true);

    [, $unicodeFloorPlan] = net_http_json('POST', "$baseUrl/scan-sessions/$unicodeSessionId/capture", ['raw_capture' => $fixtureA], $unicodeSessionToken);
    check('capture still succeeds with non-ASCII session identity', count($unicodeFloorPlan['rooms'] ?? []) === 1, 'got ' . count($unicodeFloorPlan['rooms'] ?? []));

    [$unicodePdfStatus, $unicodePdfContentType, $unicodePdfBytes] = net_http_raw('GET', "$baseUrl/scan-sessions/$unicodeSessionId/export/floorplan.pdf", null, $unicodeSessionToken);
    check('PDF export still returns HTTP 200 with a non-ASCII identity', $unicodePdfStatus === 200, "got HTTP $unicodePdfStatus");

    preg_match_all('/\(((?:[^()\\\\]|\\\\.)*)\)\s*Tj/', $unicodePdfBytes, $tjMatches);
    $hasHighByteInText = false;
    foreach ($tjMatches[1] as $shown) {
        if (preg_match('/[\x80-\xFF]/', $shown)) {
            $hasHighByteInText = true;
            break;
        }
    }
    check('no raw high-byte (non-ASCII) bytes appear inside any PDF text-showing operator', !$hasHighByteInText);

    check('the ASCII-safe prefix of property_id ("prop-caf") still appears', str_contains($unicodePdfBytes, 'prop-caf'));
    check('the ASCII-safe prefix of unit_id ("unit-Stra") still appears', str_contains($unicodePdfBytes, 'unit-Stra'));
    check('the ASCII-safe prefix of organisation_id ("org-M") still appears', str_contains($unicodePdfBytes, 'org-M'));

    check('PDF still starts with a valid %PDF- header', str_starts_with($unicodePdfBytes, '%PDF-'));
    check('PDF still ends with %%EOF', str_ends_with(rtrim($unicodePdfBytes), '%%EOF'));
    check_pdf_graph('non-ASCII identity PDF', $unicodePdfBytes);
}

echo "\n== Export unit toggle and optional label, over real HTTP ==\n";
[$imperialPdfStatus, , $imperialPdfBytes] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.pdf?unit=imperial", null, $accessToken);
check('imperial PDF export returns HTTP 200', $imperialPdfStatus === 200, "got HTTP $imperialPdfStatus");
check('imperial PDF export uses sqft, not sqm', str_contains($imperialPdfBytes, 'sqft') && !str_contains($imperialPdfBytes, 'sqm'));
check_pdf_graph('imperial-unit PDF', $imperialPdfBytes);

[$invalidUnitStatus, $invalidUnitBody] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.png?unit=bogus", null, $accessToken);
check('an invalid ?unit= value is rejected with 422', $invalidUnitStatus === 422 && ($invalidUnitBody['error'] ?? null) === 'invalid_unit', "got HTTP $invalidUnitStatus: " . json_encode($invalidUnitBody));

[$plusLabelStatus, , $plusLabelPdfBytes] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.pdf?label=Unit%203%2B1", null, $accessToken);
check('a %2B-escaped literal plus in ?label= survives as a real plus, not a space', $plusLabelStatus === 200 && str_contains($plusLabelPdfBytes, 'Unit 3+1'), 'label text was mangled');

echo "\n== Room type correction (set/clear/reject) over real HTTP ==\n";
$roomTypeRoomId = $floorPlan['rooms'][0]['room_id'] ?? null;
[$setStatus, $setBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms/$roomTypeRoomId/room-type", ['room_type' => 'kitchen'], $accessToken);
check('setting a valid room_type returns 200', $setStatus === 200, "got HTTP $setStatus");
$settedRoom = array_values(array_filter($setBody['rooms'] ?? [], static fn (array $r) => $r['room_id'] === $roomTypeRoomId))[0] ?? null;
check('the room now carries the confirmed type', ($settedRoom['room_type']['confirmed'] ?? null) === 'kitchen');

[$clearStatus, $clearBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms/$roomTypeRoomId/room-type", ['room_type' => null], $accessToken);
check('clearing a room_type (explicit null) returns 200, not a 422', $clearStatus === 200, "got HTTP $clearStatus");

[$missingKeyStatus, $missingKeyBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms/$roomTypeRoomId/room-type", [], $accessToken);
check('an absent room_type key is rejected as missing_required_fields', $missingKeyStatus === 422 && ($missingKeyBody['error'] ?? null) === 'missing_required_fields', "got HTTP $missingKeyStatus: " . json_encode($missingKeyBody));

[$falseStatus, $falseBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms/$roomTypeRoomId/room-type", ['room_type' => false], $accessToken);
check('room_type: false (present, wrong type) is rejected as invalid_room_type, not confused with a missing key', $falseStatus === 422 && ($falseBody['error'] ?? null) === 'invalid_room_type', "got HTTP $falseStatus: " . json_encode($falseBody));

[$unknownRoomStatus, $unknownRoomBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms/no-such-room/room-type", ['room_type' => 'bedroom'], $accessToken);
check('an unknown room_id is rejected as unknown_room_id', $unknownRoomStatus === 422 && ($unknownRoomBody['error'] ?? null) === 'unknown_room_id', "got HTTP $unknownRoomStatus: " . json_encode($unknownRoomBody));

echo "\n== Room label rename (set/reject) over real HTTP ==\n";
$roomLabelRoomId = $floorPlan['rooms'][0]['room_id'] ?? null;
[$setLabelStatus, $setLabelBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms/$roomLabelRoomId/label", ['label' => 'Primary Bedroom'], $accessToken);
check('setting a valid label returns 200', $setLabelStatus === 200, "got HTTP $setLabelStatus");
$labelledRoom = array_values(array_filter($setLabelBody['rooms'] ?? [], static fn (array $r) => $r['room_id'] === $roomLabelRoomId))[0] ?? null;
check('the room now carries the renamed label', ($labelledRoom['label'] ?? null) === 'Primary Bedroom', 'got ' . json_encode($labelledRoom['label'] ?? null));

[$trimLabelStatus, $trimLabelBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms/$roomLabelRoomId/label", ['label' => '  Guest Room  '], $accessToken);
check('a label with surrounding whitespace is trimmed before storage', $trimLabelStatus === 200 && (array_values(array_filter($trimLabelBody['rooms'] ?? [], static fn (array $r) => $r['room_id'] === $roomLabelRoomId))[0]['label'] ?? null) === 'Guest Room');

[$missingLabelStatus, $missingLabelBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms/$roomLabelRoomId/label", [], $accessToken);
check('an absent label key is rejected as missing_required_fields', $missingLabelStatus === 422 && ($missingLabelBody['error'] ?? null) === 'missing_required_fields', "got HTTP $missingLabelStatus: " . json_encode($missingLabelBody));

[$emptyLabelStatus, $emptyLabelBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms/$roomLabelRoomId/label", ['label' => '   '], $accessToken);
check('a whitespace-only label is rejected as invalid_room_label', $emptyLabelStatus === 422 && ($emptyLabelBody['error'] ?? null) === 'invalid_room_label', "got HTTP $emptyLabelStatus: " . json_encode($emptyLabelBody));

[$tooLongLabelStatus, $tooLongLabelBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms/$roomLabelRoomId/label", ['label' => str_repeat('x', 61)], $accessToken);
check('a label over 60 characters is rejected as invalid_room_label', $tooLongLabelStatus === 422 && ($tooLongLabelBody['error'] ?? null) === 'invalid_room_label', "got HTTP $tooLongLabelStatus: " . json_encode($tooLongLabelBody));

[$wrongTypeLabelStatus, $wrongTypeLabelBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms/$roomLabelRoomId/label", ['label' => 123], $accessToken);
check('label: 123 (present, wrong type) is rejected as missing_required_fields', $wrongTypeLabelStatus === 422 && ($wrongTypeLabelBody['error'] ?? null) === 'missing_required_fields', "got HTTP $wrongTypeLabelStatus: " . json_encode($wrongTypeLabelBody));

[$unknownRoomLabelStatus, $unknownRoomLabelBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/rooms/no-such-room/label", ['label' => 'Attic'], $accessToken);
check('an unknown room_id is rejected as unknown_room_id', $unknownRoomLabelStatus === 422 && ($unknownRoomLabelBody['error'] ?? null) === 'unknown_room_id', "got HTTP $unknownRoomLabelStatus: " . json_encode($unknownRoomLabelBody));

echo "\n== Adversarial: exports before any capture must not silently return an empty/broken file ==\n";
[, $emptySession] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-exports-empty',
    'unit_id' => 'unit-net-exports-empty',
    'organisation_id' => 'org-net-exports-empty',
    'purpose' => 'listing',
    'occupied' => false,
]);
$emptySessionId = $emptySession['id'] ?? null;
$emptySessionToken = $emptySession['access_token'] ?? null;
if ($emptySessionId !== null) {
    [$emptyPngStatus, ] = net_http_json('GET', "$baseUrl/scan-sessions/$emptySessionId/export/floorplan.png", null, $emptySessionToken);
    check('PNG export before any capture returns 404, not a broken/empty image', $emptyPngStatus === 404, "got HTTP $emptyPngStatus");

    [$emptyPdfStatus, ] = net_http_json('GET', "$baseUrl/scan-sessions/$emptySessionId/export/floorplan.pdf", null, $emptySessionToken);
    check('PDF export before any capture returns 404, not a broken/empty file', $emptyPdfStatus === 404, "got HTTP $emptyPdfStatus");
}

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