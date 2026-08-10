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
