<?php

declare(strict_types=1);

require_once __DIR__ . '/lib/http_client.php';

$baseUrl = $argv[1] ?? 'http://127.0.0.1:8089';
$bootPort = (int) ($argv[2] ?? 19511);
$appKey = getenv('SCAN_SERVICE_APP_KEY') ?: '';
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

function app_key_identity(string $suffix): array
{
    return [
        'property_id' => "prop-net-appkey-$suffix",
        'unit_id' => "unit-net-appkey-$suffix",
        'organisation_id' => 'org-net-appkey',
        'purpose' => 'listing',
        'occupied' => false,
    ];
}

function create_with(string $baseUrl, string $suffix, array $headers): array
{
    return net_http_json_ex('POST', "$baseUrl/scan-sessions", app_key_identity($suffix), null, $headers);
}

function boot_server(int $port, array $overrides): array
{
    $env = getenv();
    unset($env['SCAN_SERVICE_APP_KEY']);
    $dbDir = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'vuuro-net-boot-' . $port . '-' . bin2hex(random_bytes(4));
    mkdir($dbDir, 0700, true);
    $env = array_merge($env, [
        'SCAN_SERVICE_ENV' => 'production',
        'SCAN_SERVICE_ADMIN_API_KEY' => 'net-boot-admin-key-0123456789abcdef',
        'SCAN_SERVICE_EXPORT_SECRET' => 'net-boot-export-secret-0123456789abcdef',
        'SCAN_SERVICE_DB_PATH' => $dbDir . DIRECTORY_SEPARATOR . 'scan_service.sqlite',
    ], $overrides);
    $root = dirname(__DIR__);
    $log = $dbDir . DIRECTORY_SEPARATOR . 'server.log';
    $process = proc_open(
        [PHP_BINARY, '-d', 'display_errors=0', '-S', "127.0.0.1:$port", 'public/index.php'],
        [0 => ['pipe', 'r'], 1 => ['file', $log, 'a'], 2 => ['file', $log, 'a']],
        $pipes,
        $root,
        $env
    );
    for ($i = 0; $i < 40; $i++) {
        $socket = @fsockopen('127.0.0.1', $port, $errno, $errstr, 0.25);
        if ($socket !== false) {
            fclose($socket);
            break;
        }
        usleep(250000);
    }
    return [$process, $dbDir];
}

function stop_server(array $server): void
{
    [$process, $dbDir] = $server;
    if (is_resource($process)) {
        proc_terminate($process);
        proc_close($process);
    }
    foreach (glob($dbDir . DIRECTORY_SEPARATOR . '*') ?: [] as $file) {
        @unlink($file);
    }
    @rmdir($dbDir);
}

check('this suite runs against a server with an app key set', strlen($appKey) >= 24, 'SCAN_SERVICE_APP_KEY is missing in the net harness');

echo "== Starting a scan needs the app key ==\n";
[$noKeyStatus, $noKey] = create_with($baseUrl, 'none', ['X-Forwarded-For' => '198.51.100.1']);
check('no key is refused with 401', $noKeyStatus === 401, "got HTTP $noKeyStatus");
check('no key names the app key error', ($noKey['error'] ?? null) === 'invalid_or_missing_app_key', json_encode($noKey));
check('no key does not hand out a token', !isset($noKey['access_token']), json_encode($noKey));
[$wrongStatus, $wrong] = create_with($baseUrl, 'wrong', ['X-Scan-App-Key' => $appKey . 'x', 'X-Forwarded-For' => '198.51.100.1']);
check('a wrong key is refused with 401', $wrongStatus === 401 && ($wrong['error'] ?? null) === 'invalid_or_missing_app_key', "got HTTP $wrongStatus");
[$emptyStatus] = create_with($baseUrl, 'empty', ['X-Scan-App-Key' => '', 'X-Forwarded-For' => '198.51.100.1']);
check('an empty key is refused with 401', $emptyStatus === 401, "got HTTP $emptyStatus");
[$rightStatus, $right] = create_with($baseUrl, 'right', ['X-Scan-App-Key' => $appKey, 'X-Forwarded-For' => '198.51.100.2']);
check('the right key starts a scan', $rightStatus === 201 && is_string($right['access_token'] ?? null), "got HTTP $rightStatus");
$sessionId = $right['id'] ?? '';
[$readStatus] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId", null, $right['access_token'] ?? '');
check('the session token alone still opens the scan afterwards', $readStatus === 200, "got HTTP $readStatus");
[$listStatus] = net_http_json_ex('GET', "$baseUrl/scan-sessions", null, null, ['X-Scan-App-Key' => $appKey]);
check('the app key does not open the admin list', $listStatus === 401, "got HTTP $listStatus");

echo "\n== Refused attempts are rate limited ==\n";
$lastStatus = 0;
for ($i = 0; $i < 21; $i++) {
    [$lastStatus] = create_with($baseUrl, "flood-$i", ['X-Scan-App-Key' => 'guess-' . $i, 'X-Forwarded-For' => '198.51.100.3']);
}
check('the 21st wrong key from one IP gets 429', $lastStatus === 429, "got HTTP $lastStatus");
[$otherIpStatus] = create_with($baseUrl, 'other-ip', ['X-Scan-App-Key' => 'guess', 'X-Forwarded-For' => '198.51.100.4']);
check('another IP still gets a plain 401', $otherIpStatus === 401, "got HTTP $otherIpStatus");

echo "\n== The client IP behind the proxy cannot be spoofed ==\n";
$statuses = [];
for ($i = 0; $i < 4; $i++) {
    [$statuses[]] = create_with($baseUrl, "spoof-$i", ['X-Scan-App-Key' => $appKey, 'X-Forwarded-For' => "203.0.113.$i, 198.51.100.9"]);
}
check('the first 3 scans from one real IP are allowed', array_slice($statuses, 0, 3) === [201, 201, 201], json_encode($statuses));
check('a fake left-most X-Forwarded-For does not reset the limit', $statuses[3] === 429, json_encode($statuses));
[$trustedHopStatus] = create_with($baseUrl, 'trusted-hop', ['X-Scan-App-Key' => $appKey, 'X-Forwarded-For' => '198.51.100.9, 172.18.0.5']);
check('a trusted proxy hop on the right is skipped to the real client', $trustedHopStatus === 429, "got HTTP $trustedHopStatus");
[$freshStatus] = create_with($baseUrl, 'fresh-ip', ['X-Scan-App-Key' => $appKey, 'X-Forwarded-For' => '198.51.100.10']);
check('a different real IP is still allowed', $freshStatus === 201, "got HTTP $freshStatus");

echo "\n== Production refuses to run without a real app key ==\n";
$server = boot_server($bootPort, []);
[$healthStatus, $health] = net_http_json('GET', "http://127.0.0.1:$bootPort/health");
check('production without an app key fails every request', $healthStatus === 500 && ($health['error'] ?? null) === 'internal_error', "got HTTP $healthStatus");
stop_server($server);
$server = boot_server($bootPort, ['SCAN_SERVICE_APP_KEY' => 'too-short-key']);
[$shortStatus] = net_http_json('GET', "http://127.0.0.1:$bootPort/health");
check('production with a short app key fails every request', $shortStatus === 500, "got HTTP $shortStatus");
stop_server($server);
$prodKey = 'net-boot-app-key-0123456789abcdef';
$server = boot_server($bootPort, ['SCAN_SERVICE_APP_KEY' => $prodKey]);
[$okStatus] = net_http_json('GET', "http://127.0.0.1:$bootPort/health");
check('production with a real app key answers /health', $okStatus === 200, "got HTTP $okStatus");
[$prodNoKey] = net_http_json('POST', "http://127.0.0.1:$bootPort/scan-sessions", app_key_identity('prod-none'));
check('production refuses a scan without the key', $prodNoKey === 401, "got HTTP $prodNoKey");
[$prodWithKey] = net_http_json_ex('POST', "http://127.0.0.1:$bootPort/scan-sessions", app_key_identity('prod-key'), null, ['X-Scan-App-Key' => $prodKey]);
check('production starts a scan with the key', $prodWithKey === 201, "got HTTP $prodWithKey");
stop_server($server);

echo "\n== Local dev without an app key keeps working ==\n";
$server = boot_server($bootPort, ['SCAN_SERVICE_ENV' => 'development']);
[$devStatus] = net_http_json('POST', "http://127.0.0.1:$bootPort/scan-sessions", app_key_identity('dev'));
check('dev mode without a configured key starts a scan with no header', $devStatus === 201, "got HTTP $devStatus");
stop_server($server);

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
