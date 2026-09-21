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

function net_http_multipart_with_admin(string $url, string $filePath, string $adminKey, string $mime = 'application/json'): array
{
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_POST => true,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HTTPHEADER => ["X-Admin-Api-Key: $adminKey"],
        CURLOPT_POSTFIELDS => ['file' => new \CURLFile($filePath, $mime, basename($filePath))],
        CURLOPT_CONNECTTIMEOUT_MS => 3000,
        CURLOPT_TIMEOUT => 30,
    ]);
    $raw = curl_exec($ch);
    $status = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    $decoded = json_decode((string) $raw, true);
    return [$status, is_array($decoded) ? $decoded : [], (string) $raw];
}

echo "== Setup: create a session, capture a room, export .vuuroscan ==\n";

$suffix = substr(md5((string) microtime(true)), 0, 8);
[$createStatus, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => "prop-net-import-$suffix",
    'unit_id' => "unit-net-import-$suffix",
    'organisation_id' => "org-net-import-$suffix",
    'purpose' => 'listing',
    'occupied' => false,
]);
check('session created (HTTP 201)', $createStatus === 201, "got HTTP $createStatus");
$sessionId = $session['id'] ?? null;
$accessToken = $session['access_token'] ?? null;
check('session id + token present', $sessionId !== null && $accessToken !== null);

$fixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);
[$captureStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixture], $accessToken);
check('room captured (HTTP 200)', $captureStatus === 200, "got HTTP $captureStatus");

[$bundleStatus, , $bundleBytes] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/vuuroscan", null, $accessToken);
check('bundle exported (HTTP 200)', $bundleStatus === 200, "got HTTP $bundleStatus");

$bundlePath = tempnam(sys_get_temp_dir(), 'vuuroscan_import_') . '.vuuroscan';
file_put_contents($bundlePath, $bundleBytes);
check('bundle written to temp file', is_file($bundlePath) && filesize($bundlePath) > 100, 'temp file: ' . $bundlePath);

echo "\n== Import: admin-gated, valid bundle accepted ==\n";

[$noKeyStatus, ] = net_http_multipart_with_admin("$baseUrl/imported-scans", $bundlePath, 'wrong-admin-key');
check('import without a valid admin key is rejected (HTTP 401)', $noKeyStatus === 401, "got HTTP $noKeyStatus");

[$importStatus, $importBody] = net_http_multipart_with_admin("$baseUrl/imported-scans", $bundlePath, $adminApiKey);
check('import with a valid admin key succeeds (HTTP 201)', $importStatus === 201, "got HTTP $importStatus, body: " . substr((string) json_encode($importBody), 0, 300));

$importId = $importBody['import_id'] ?? null;
check('import response carries import_id', is_string($importId) && $importId !== '');
check('import response carries the original property_id', ($importBody['property_id'] ?? null) === "prop-net-import-$suffix");
check('import response carries the original unit_id', ($importBody['unit_id'] ?? null) === "unit-net-import-$suffix");
check('import response carries the original organisation_id', ($importBody['organisation_id'] ?? null) === "org-net-import-$suffix");
check('import response carries the original session_id', ($importBody['session_id'] ?? null) === $sessionId);
check('import response has a signature_status', in_array($importBody['signature_status'] ?? null, ['valid', 'unsigned', 'unverified'], true), 'got: ' . ($importBody['signature_status'] ?? 'null'));

echo "\n== List: imports appear alongside native sessions ==\n";

[$listStatus, $listBody] = net_http_json_ex('GET', "$baseUrl/imported-scans", null, null, ['X-Admin-Api-Key' => $adminApiKey]);
check('list imports returns HTTP 200', $listStatus === 200, "got HTTP $listStatus");
$importIds = array_column($listBody['imports'] ?? [], 'import_id');
check('list contains the just-imported scan', is_string($importId) && in_array($importId, $importIds, true), 'import id not in list');

[$noKeyListStatus, ] = net_http_json_ex('GET', "$baseUrl/imported-scans", null, null, []);
check('list imports without an admin key is rejected (HTTP 401)', $noKeyListStatus === 401, "got HTTP $noKeyListStatus");

[$filteredStatus, $filteredBody] = net_http_json_ex('GET', "$baseUrl/imported-scans?property_id=prop-net-import-$suffix", null, null, ['X-Admin-Api-Key' => $adminApiKey]);
check('filtered list returns HTTP 200', $filteredStatus === 200, "got HTTP $filteredStatus");
$filteredIds = array_column($filteredBody['imports'] ?? [], 'import_id');
check('filtered list contains only our import', is_string($importId) && in_array($importId, $filteredIds, true));

echo "\n== Detail: full payload round-trips ==\n";

if (is_string($importId)) {
    [$detailStatus, $detailBody] = net_http_json_ex('GET', "$baseUrl/imported-scans/$importId", null, null, ['X-Admin-Api-Key' => $adminApiKey]);
    check('detail returns HTTP 200', $detailStatus === 200, "got HTTP $detailStatus");
    check('detail carries import_id', ($detailBody['import_id'] ?? null) === $importId);
    check('detail carries payload object', is_array($detailBody['payload'] ?? null));
    check('detail payload format is vuuroscan/1', ($detailBody['payload']['format'] ?? null) === 'vuuroscan/1');
    check('detail payload carries floor_plan.rooms', isset($detailBody['payload']['floor_plan']['rooms']) && is_array($detailBody['payload']['floor_plan']['rooms']));
    check('detail payload carries exports.png_base64', is_string($detailBody['payload']['exports']['png_base64'] ?? null));
    check('detail payload carries exports.pdf_base64', is_string($detailBody['payload']['exports']['pdf_base64'] ?? null));

    [$missingStatus, ] = net_http_json_ex('GET', "$baseUrl/imported-scans/does-not-exist-$suffix", null, null, ['X-Admin-Api-Key' => $adminApiKey]);
    check('detail for an unknown import_id returns HTTP 404', $missingStatus === 404, "got HTTP $missingStatus");
}

echo "\n== Reject: malformed and unsupported files ==\n";

$badPath = tempnam(sys_get_temp_dir(), 'vuuroscan_bad_') . '.vuuroscan';
file_put_contents($badPath, 'not json at all');
[$badStatus, $badBody] = net_http_multipart_with_admin("$baseUrl/imported-scans", $badPath, $adminApiKey);
check('non-JSON file rejected (HTTP 422)', $badStatus === 422, "got HTTP $badStatus");
check('non-JSON rejection uses invalid_json error', ($badBody['error'] ?? null) === 'invalid_json', 'got: ' . ($badBody['error'] ?? 'null'));
unlink($badPath);

$wrongFormatPath = tempnam(sys_get_temp_dir(), 'vuuroscan_wrong_') . '.vuuroscan';
file_put_contents($wrongFormatPath, json_encode(['format' => 'something-else', 'session' => ['id' => 'x']], JSON_THROW_ON_ERROR));
[$wrongFormatStatus, $wrongFormatBody] = net_http_multipart_with_admin("$baseUrl/imported-scans", $wrongFormatPath, $adminApiKey);
check('unknown format rejected (HTTP 422)', $wrongFormatStatus === 422, "got HTTP $wrongFormatStatus");
check('unknown format rejection uses unsupported_format error', ($wrongFormatBody['error'] ?? null) === 'unsupported_format', 'got: ' . ($wrongFormatBody['error'] ?? 'null'));
unlink($wrongFormatPath);

$missingSessionPath = tempnam(sys_get_temp_dir(), 'vuuroscan_missingsess_') . '.vuuroscan';
file_put_contents($missingSessionPath, json_encode(['format' => 'vuuroscan/1', 'floor_plan' => ['rooms' => []]], JSON_THROW_ON_ERROR));
[$missingSessionStatus, $missingSessionBody] = net_http_multipart_with_admin("$baseUrl/imported-scans", $missingSessionPath, $adminApiKey);
check('bundle missing session block rejected (HTTP 422)', $missingSessionStatus === 422, "got HTTP $missingSessionStatus");
check('missing-session rejection uses malformed_bundle error', ($missingSessionBody['error'] ?? null) === 'malformed_bundle', 'got: ' . ($missingSessionBody['error'] ?? 'null'));
unlink($missingSessionPath);

echo "\n== Tampered bundle (signature invalid) rejected when a secret is set ==\n";

$tamperedBundle = json_decode((string) $bundleBytes, true);
if (is_array($tamperedBundle) && isset($tamperedBundle['signature']['value'])) {
    $tamperedBundle['floor_plan']['rooms'][0]['floor_area_m2'] = 9999.99;
    $tamperedPath = tempnam(sys_get_temp_dir(), 'vuuroscan_tampered_') . '.vuuroscan';
    file_put_contents($tamperedPath, json_encode($tamperedBundle, JSON_THROW_ON_ERROR));
    [$tamperedStatus, $tamperedBody] = net_http_multipart_with_admin("$baseUrl/imported-scans", $tamperedPath, $adminApiKey);
    check(
        'tampered bundle is rejected (HTTP 422 signature_invalid)',
        $tamperedStatus === 422 && ($tamperedBody['error'] ?? null) === 'signature_invalid',
        'got HTTP ' . $tamperedStatus . ' error=' . ($tamperedBody['error'] ?? 'null')
    );
    unlink($tamperedPath);
} else {
    echo "  [SKIP] signature check — this server has no SCAN_SERVICE_EXPORT_SECRET, so no signed bundle exists to tamper with\n";
}

unlink($bundlePath);

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
