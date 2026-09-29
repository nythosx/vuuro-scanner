<?php

declare(strict_types=1);

require_once __DIR__ . '/lib/http_client.php';

$baseUrl = $argv[1] ?? 'http://127.0.0.1:8089';
$adminKey = $argv[2] ?? 'net-test-admin-key';
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

function admin_call(string $method, string $url, ?array $body, string $key): array
{
    [$status, , $raw] = net_http_raw_literal($method, $url, $body === null ? null : json_encode($body, JSON_THROW_ON_ERROR), null, ['X-Admin-Api-Key' => $key]);
    return [$status, json_decode((string) $raw, true)];
}

echo "== Access ==\n";
[$noKeyStatus] = admin_call('GET', "$baseUrl/admin/settings", null, '');
check('settings need the admin key', $noKeyStatus === 401, "got HTTP $noKeyStatus");
[$wrongKeyStatus] = admin_call('POST', "$baseUrl/admin/settings", ['tenant_deletion' => ['enabled' => false]], 'wrong-key');
check('a wrong key cannot change settings', $wrongKeyStatus === 401, "got HTTP $wrongKeyStatus");
[$getStatus, $initial] = admin_call('GET', "$baseUrl/admin/settings", null, $adminKey);
check('GET /admin/settings returns JSON, not the admin page', $getStatus === 200 && isset($initial['retention']['listing'], $initial['tenant_deletion']), "HTTP $getStatus");

[$slashStatus, $slashBody] = admin_call('GET', "$baseUrl/admin/settings/", null, $adminKey);
check('a trailing slash still reaches the settings API', $slashStatus === 200 && isset($slashBody['retention']), "HTTP $slashStatus");
[$identitiesStatus] = admin_call('GET', "$baseUrl/admin/recent-identities/", null, $adminKey);
check('a trailing slash still reaches recent identities', $identitiesStatus === 200, "HTTP $identitiesStatus");

echo "\n== Validation ==\n";
[$badStatus, $badBody] = admin_call('POST', "$baseUrl/admin/settings", ['retention' => ['listing' => ['days' => 0]]], $adminKey);
check('invalid days are a 422 with a readable message', $badStatus === 422 && ($badBody['error'] ?? null) === 'invalid_settings', json_encode($badBody));

echo "\n== Tenant deletion switch ==\n";
[, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
    'property_id' => 'prop-net-settings', 'unit_id' => 'unit-net-settings', 'organisation_id' => 'org-net-settings',
    'purpose' => 'check_out', 'occupied' => false,
]);
$sessionId = $session['id'];
$token = $session['access_token'];
[$offStatus, $off] = admin_call('POST', "$baseUrl/admin/settings", ['tenant_deletion' => ['enabled' => false, 'grace_days' => 10], 'retention' => ['check_out' => ['enabled' => true, 'days' => 45]]], $adminKey);
check('switching tenant deletion off and a retention rule on is saved', $offStatus === 200 && $off['tenant_deletion']['enabled'] === false && $off['retention']['check_out']['enabled'] === true && $off['retention']['check_out']['days'] === 45 && $off['retention']['check_out']['source'] === 'admin', json_encode($off));
[$statusCode, $status] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId/deletion-request", null, $token);
check('the app sees that requests are off and the new grace days', $statusCode === 200 && ($status['requests_enabled'] ?? null) === false && ($status['grace_period_days'] ?? null) === 10, json_encode($status));
[$requestStatus, $requestBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/request-deletion", [], $token);
check('a deletion request is refused while switched off', $requestStatus === 403 && ($requestBody['error'] ?? null) === 'tenant_deletion_disabled', "HTTP $requestStatus " . json_encode($requestBody));
[$runStatus, $run] = admin_call('POST', "$baseUrl/admin/run-retention", null, $adminKey);
check('clean-up runs with the admin rules and keeps a fresh scan', $runStatus === 200 && is_int($run['purged'] ?? null), "HTTP $runStatus");
[$stillThere] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId", null, $token);
check('a scan younger than the rule is not deleted', $stillThere === 200, "got HTTP $stillThere");

[$onStatus] = admin_call('POST', "$baseUrl/admin/settings", ['tenant_deletion' => ['enabled' => true, 'grace_days' => 7]], $adminKey);
[$requestAgain, $requested] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/request-deletion", [], $token);
check('switched back on, a tenant can request deletion again', $onStatus === 200 && $requestAgain === 200 && ($requested['requested'] ?? null) === true, "HTTP $requestAgain");

[$historyStatus, $historyBody] = admin_call('GET', "$baseUrl/admin/settings/history", null, $adminKey);
$latest = $historyBody['changes'][0] ?? [];
check('the settings log records the change, with who made it', $historyStatus === 200 && str_starts_with((string) ($latest['actor'] ?? ''), 'admin key ') && ($latest['after']['tenant_deletion']['enabled'] ?? null) === true, json_encode($latest));
check('the log never contains the admin key itself', !str_contains(json_encode($historyBody), $adminKey));

echo "
== Automatic plan follows the purpose ==
";
$fixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);
net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixture], $token);
admin_call('POST', "$baseUrl/admin/settings", ['plan_style' => ['check_out' => 'listing']], $adminKey);
[, , $autoListing] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.svg?style=auto", null, $token);
[, , $funda] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.svg?style=funda", null, $token);
check('style=auto gives the Listing plan when that is the purpose default', $autoListing !== '' && $autoListing === $funda);
admin_call('POST', "$baseUrl/admin/settings", ['plan_style' => ['check_out' => 'full']], $adminKey);
[$autoStatus, , $autoFull] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.svg?style=auto", null, $token);
[, , $full] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.svg", null, $token);
check('style=auto gives the Full report once the admin switches check-out to it', $autoStatus === 200 && $autoFull === $full && $autoFull !== $funda);
[$badStyle] = net_http_raw('GET', "$baseUrl/scan-sessions/$sessionId/export/floorplan.svg?style=fancy", null, $token);
check('an unknown style is still refused', $badStyle === 422, "got HTTP $badStyle");

$restore = ['tenant_deletion' => $initial['tenant_deletion'], 'plan_style' => $initial['plan_style'], 'retention' => []];
foreach ($initial['retention'] as $purpose => $rule) {
    $restore['retention'][$purpose] = $rule['source'] === 'admin' ? ['enabled' => $rule['enabled'], 'days' => $rule['days']] : null;
}
[$restoreStatus] = admin_call('POST', "$baseUrl/admin/settings", $restore, $adminKey);
check('settings are put back for the other suites', $restoreStatus === 200, "HTTP $restoreStatus");
[, $restored] = admin_call('GET', "$baseUrl/admin/settings", null, $adminKey);
check('purposes that were not set here go back to the server config or default', array_column($restored['retention'] ?? [], 'source') === array_column($initial['retention'], 'source'), json_encode(array_column($restored['retention'] ?? [], 'source')));

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
