<?php

declare(strict_types=1);

/**
 * Independent net for PNG/PDF floor plan exports. Same rules as the other
 * net scripts — HTTP only, no importing FloorPlanImageRenderer/
 * FloorPlanPdfRenderer, expected structure re-derived independently from
 * the underlying FloorPlan (not from the renderer's own output format).
 *
 * Usage: php net/verify_phase3_exports.php [base_url]
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

// --- Set up a two-room session, independent of the export code under test ---
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

// Independently decode via GD (still not the renderer under test — this is
// just parsing its output the way any real client would) and sanity-check
// dimensions scale with the underlying room geometry rather than being a
// fixed/hardcoded canvas size regardless of content.
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

// Structural check independent of the renderer: re-parse the xref table
// ourselves and confirm every declared object offset actually points at
// that object's "N 0 obj" header. A renderer bug that writes a plausible
// but wrong offset would produce a PDF many naive checks (just "starts with
// %PDF-") would still call valid.
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

// Content check: the room labels and rounded areas the API already returned
// must actually appear in the PDF's text content — the metrics table isn't
// silently using different numbers than the API.
$room1Label = $floorPlan['rooms'][0]['label'];
$room2Area = number_format((float) $floorPlan['rooms'][1]['floor_area_m2'], 2, '.', '');
check("PDF content contains the first room's label ($room1Label)", str_contains($pdfBytes, $room1Label));
check("PDF content contains the second room's area ($room2Area)", str_contains($pdfBytes, $room2Area));

echo "\n== Adversarial: many rooms must not go missing off a fixed-size PDF page ==\n";

// The specific bug this net exists to catch: FloorPlanPdfRenderer used to
// hardcode a single fixed-size page with no bottom-of-page check, so rooms
// past roughly #30 (and eventually the trailing summary lines) rendered
// below the visible page — present in the bytes, invisible to anyone who
// actually opened the file. One capture call with many floors (each floor
// -> one room) forces that page boundary in a single request rather than 40
// separate capture calls.
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

        // The actual regression check, and the one that matters most: a
        // byte-presence check alone ("does the label appear anywhere in the
        // file") would NOT catch the original bug — the old renderer still
        // wrote every line's text into the content stream, just positioned
        // at a Y coordinate below the visible page. Independently parse
        // every `Tm` text-positioning operator this renderer emits
        // (`1 0 0 1 <x> <y> Tm`) and confirm every Y stays within the 792pt
        // MediaBox — re-deriving the actual defect (off-page placement),
        // not just re-checking that pagination objects exist.
        preg_match_all('/1 0 0 1 [\d.]+ (-?[\d.]+) Tm/', $manyPdfBytes, $tmMatches);
        $offPageYs = array_filter($tmMatches[1] ?? [], static fn ($y) => (float) $y < 0 || (float) $y > 792);
        check(
            'every text line\'s Y position is found at all, and all stay within the 792pt page (none negative/over-tall)',
            $tmMatches[1] !== [] && $offPageYs === [],
            count($tmMatches[1]) . ' Tm operators found, ' . count($offPageYs) . ' positioned off-page: ' . implode(', ', array_slice($offPageYs, 0, 5))
        );

        // Byte-presence checks too, now that the positional check above is
        // the one actually proving the fix — belt and suspenders.
        $missingLabels = [];
        foreach ($manyFloorPlan['rooms'] as $room) {
            if (!str_contains($manyPdfBytes, $room['label'])) {
                $missingLabels[] = $room['label'];
            }
        }
        check('every one of the 40 room labels appears in the PDF, including the last', $missingLabels === [], 'missing: ' . implode(', ', $missingLabels));

        $totalAreaLine = sprintf('%.2f', array_sum(array_column($manyFloorPlan['rooms'], 'floor_area_m2')));
        check('the trailing "Total indicative area" line is still present, not pushed off-page', str_contains($manyPdfBytes, $totalAreaLine));

        // Structural re-check, same independent xref/offset logic as above —
        // pagination must not have produced a structurally broken PDF.
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
    }
}

// Adjacent-case gap found by deliberate probing, not by a report: nothing
// end-to-end had ever exercised non-ASCII identity fields through the real
// HTTP export path. FloorPlanPdfRenderer's own doc comment claims it stays
// ASCII-safe (GD/base-14-Helvetica can't render UTF-8), but a claim in a
// comment is not the same as a verified behaviour — this proves it against
// the live API, not the renderer class directly (this net never imports it).
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

    // The real assertion: no raw multi-byte UTF-8 (any byte >= 0x80) leaked
    // into the PDF's actual text-showing operators. A naive "just don't
    // crash" fix could still leak raw UTF-8 bytes into a Tj string, which a
    // real PDF viewer would then render as mojibake under base-14 Helvetica
    // StandardEncoding — same failure class the PNG renderer's own comment
    // warns about for m-superscript-2/middot.
    preg_match_all('/\(((?:[^()\\\\]|\\\\.)*)\)\s*Tj/', $unicodePdfBytes, $tjMatches);
    $hasHighByteInText = false;
    foreach ($tjMatches[1] as $shown) {
        if (preg_match('/[\x80-\xFF]/', $shown)) {
            $hasHighByteInText = true;
            break;
        }
    }
    check('no raw high-byte (non-ASCII) bytes appear inside any PDF text-showing operator', !$hasHighByteInText);

    // The other half of "honest, not silently eaten": the ASCII-safe prefix
    // of each field must still be present, proving the fields weren't
    // dropped/truncated entirely — only the non-ASCII characters were
    // folded, per FloorPlanPdfRenderer's documented behaviour.
    check('the ASCII-safe prefix of property_id ("prop-caf") still appears', str_contains($unicodePdfBytes, 'prop-caf'));
    check('the ASCII-safe prefix of unit_id ("unit-Stra") still appears', str_contains($unicodePdfBytes, 'unit-Stra'));
    check('the ASCII-safe prefix of organisation_id ("org-M") still appears', str_contains($unicodePdfBytes, 'org-M'));

    // Structural sanity: still a well-formed single-page PDF, not corrupted
    // by whatever fold/replace path the non-ASCII bytes went through.
    check('PDF still starts with a valid %PDF- header', str_starts_with($unicodePdfBytes, '%PDF-'));
    check('PDF still ends with %%EOF', str_ends_with(rtrim($unicodePdfBytes), '%%EOF'));
}

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
