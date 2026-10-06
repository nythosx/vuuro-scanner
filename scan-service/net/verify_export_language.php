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

function export_get(string $baseUrl, string $id, string $token, string $file, string $query): array
{
    [$status, , $raw] = net_http_raw_literal('GET', "$baseUrl/scan-sessions/$id/export/$file$query", null, $token);
    return [$status, $raw];
}

[, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-lang',
    'unit_id' => 'unit-net-lang-' . bin2hex(random_bytes(3)),
    'organisation_id' => 'org-net-lang',
    'purpose' => 'check_out',
    'occupied' => false,
    'floor' => 'Ground',
]);
$id = $session['id'] ?? '';
$token = $session['access_token'] ?? '';
$raw = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_openings_and_objects.json'), true, 512, JSON_THROW_ON_ERROR);
[$captureStatus] = net_http_json('POST', "$baseUrl/scan-sessions/$id/capture", ['raw_capture' => $raw, 'floor' => 'Ground'], $token);
check('a room is captured', $captureStatus === 200, "got HTTP $captureStatus");

echo "== ?lang= on the exports ==\n";
[$nlStatus, $nlPdf] = export_get($baseUrl, $id, $token, 'floorplan.pdf', '?style=default&lang=nl');
check('the Dutch PDF is Dutch', $nlStatus === 200 && str_contains($nlPdf, '(Maten van de plattegrond)') && !str_contains($nlPdf, '(Floor Plan Metrics)'), "got HTTP $nlStatus");
[$enStatus, $enPdf] = export_get($baseUrl, $id, $token, 'floorplan.pdf', '?style=default&lang=en');
check('the English PDF is English', $enStatus === 200 && str_contains($enPdf, '(Floor Plan Metrics)'), "got HTTP $enStatus");
[$plainStatus, $plainPdf] = export_get($baseUrl, $id, $token, 'floorplan.pdf', '?style=default');
check('without lang the PDF stays English by default', $plainStatus === 200 && str_contains($plainPdf, '(Floor Plan Metrics)'), "got HTTP $plainStatus");
[$badStatus, $bad] = export_get($baseUrl, $id, $token, 'floorplan.pdf', '?lang=de');
check('an unknown language is refused', $badStatus === 422 && str_contains($bad, 'invalid_lang'), "got HTTP $badStatus");
[$badPngStatus] = export_get($baseUrl, $id, $token, 'floorplan.png', '?lang=NL');
check('the language code is exact on the PNG too', $badPngStatus === 422, "got HTTP $badPngStatus");
[$nlPngStatus, $nlPng] = export_get($baseUrl, $id, $token, 'floorplan.png', '?style=default&lang=nl');
[$enPngStatus, $enPng] = export_get($baseUrl, $id, $token, 'floorplan.png', '?style=default&lang=en');
check('the Dutch PNG is drawn differently', $nlPngStatus === 200 && $enPngStatus === 200 && $nlPng !== $enPng);
[$nlSvgStatus, $nlSvg] = export_get($baseUrl, $id, $token, 'floorplan.svg', '?style=default&lang=nl');
check('the Dutch SVG has the Dutch footer', $nlSvgStatus === 200 && str_contains($nlSvg, 'niet gecertificeerd'), "got HTTP $nlSvgStatus");

echo "\n== Admin default for older app builds ==\n";
[$setStatus] = net_http_json_ex('POST', "$baseUrl/admin/settings", ['export_language' => 'nl'], null, ['X-Admin-Api-Key' => $adminKey]);
[, $defaultPdf] = export_get($baseUrl, $id, $token, 'floorplan.pdf', '?style=default');
check('without lang the admin default is used', $setStatus === 200 && str_contains($defaultPdf, '(Maten van de plattegrond)'), "got HTTP $setStatus");
[, $pinnedPdf] = export_get($baseUrl, $id, $token, 'floorplan.pdf', '?style=default&lang=en');
check('lang from the app wins over the admin default', str_contains($pinnedPdf, '(Floor Plan Metrics)'));
[$resetStatus] = net_http_json_ex('POST', "$baseUrl/admin/settings", ['export_language' => 'en'], null, ['X-Admin-Api-Key' => $adminKey]);
[, $afterReset] = export_get($baseUrl, $id, $token, 'floorplan.pdf', '?style=default');
check('the default can be switched back to English', $resetStatus === 200 && str_contains($afterReset, '(Floor Plan Metrics)'));
[$readStatus, $plan] = net_http_json('GET', "$baseUrl/scan-sessions/$id", null, $token);
check('the JSON API is not translated', $readStatus === 200 && str_starts_with((string) ($plan['rooms'][0]['label'] ?? ''), 'Room'), json_encode($plan['rooms'][0]['label'] ?? null));

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
