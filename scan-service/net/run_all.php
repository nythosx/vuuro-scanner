<?php

declare(strict_types=1);

$root = dirname(__DIR__);
$mainPort = (int) ($argv[1] ?? 18089);
$standalonePort = (int) ($argv[2] ?? 19499);
$appKeyPort = (int) ($argv[3] ?? 19509);
$appKeyBootPort = (int) ($argv[4] ?? 19511);
$adminKey = 'ci-test-admin-key';

$groups = [
    [
        'name' => 'shared server',
        'port' => $mainPort,
        'env' => [
            'SCAN_SERVICE_RATE_LIMIT_CREATE_SESSION_MAX' => '2000',
            'SCAN_SERVICE_RATE_LIMIT_CREATE_SESSION_WINDOW_SECONDS' => '600',
            'SCAN_SERVICE_RATE_LIMIT_POST_BODY_READ_MAX' => '4000',
            'SCAN_SERVICE_ADMIN_API_KEY' => $adminKey,
        ],
        'scripts' => [
            ['verify_capture_geometry.php'],
            ['verify_multiroom_and_attachments.php'],
            ['verify_multiroom_fusion.php'],
            ['verify_exports.php'],
            ['verify_acl.php'],
            ['verify_coverage.php'],
            ['verify_openings_and_objects.php'],
            ['verify_security_fixes.php'],
            ['verify_error_messages.php'],
            ['verify_session_delete.php'],
            ['verify_replace_rooms.php'],
            ['verify_walk_path.php'],
            ['verify_session_lookup_and_item_delete.php', $adminKey],
            ['verify_crud.php'],
            ['verify_delete_and_fusion_hardening.php'],
            ['verify_floor_and_style.php'],
            ['verify_activity.php'],
            ['verify_admin_settings.php', $adminKey],
            ['verify_room_split.php'],
            ['verify_room_floor_and_delete.php'],
            ['verify_group_placement.php'],
            ['verify_rescan_replace.php'],
            ['verify_continue_edges.php'],
            ['verify_compare.php'],
            ['verify_export_language.php'],
            ['verify_enterprise_hardening.php'],
        ],
    ],
    [
        'name' => 'app key server',
        'port' => $appKeyPort,
        'env' => [
            'SCAN_SERVICE_APP_KEY' => 'ci-test-app-key-0123456789abcdef',
            'SCAN_SERVICE_RATE_LIMIT_CREATE_SESSION_MAX' => '3',
            'SCAN_SERVICE_RATE_LIMIT_POST_BODY_READ_MAX' => '4000',
        ],
        'scripts' => [
            ['verify_app_key.php', (string) $appKeyBootPort],
        ],
    ],
    [
        'name' => 'standalone server',
        'port' => $standalonePort,
        'env' => [
            'SCAN_SERVICE_RATE_LIMIT_POST_BODY_READ_MAX' => '4000',
        ],
        'scripts' => [
            ['verify_post_body_read_rate_limit.php'],
        ],
    ],
];

function startServer(string $root, int $port, array $env): array
{
    $dbDir = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'vuuro-net-' . $port . '-' . bin2hex(random_bytes(4));
    mkdir($dbDir, 0700, true);
    $env['SCAN_SERVICE_DB_PATH'] = $dbDir . DIRECTORY_SEPARATOR . 'scan_service.sqlite';
    $process = proc_open(
        [PHP_BINARY, '-d', 'post_max_size=30M', '-d', 'upload_max_filesize=26M', '-d', 'display_errors=0', '-S', "127.0.0.1:$port", 'public/index.php'],
        [0 => ['pipe', 'r'], 1 => ['file', $dbDir . DIRECTORY_SEPARATOR . 'server.log', 'a'], 2 => ['file', $dbDir . DIRECTORY_SEPARATOR . 'server.log', 'a']],
        $pipes,
        $root,
        array_merge(getenv(), $env)
    );
    if (!is_resource($process)) {
        fwrite(STDERR, "Could not start the Scan Service on port $port\n");
        exit(2);
    }
    for ($i = 0; $i < 40; $i++) {
        $health = @file_get_contents("http://127.0.0.1:$port/health");
        if ($health !== false) {
            return [$process, $dbDir, $env];
        }
        usleep(250000);
    }
    proc_terminate($process);
    fwrite(STDERR, "Scan Service on port $port did not answer /health\n");
    exit(2);
}

function removeDir(string $dir): void
{
    foreach (glob($dir . DIRECTORY_SEPARATOR . '{,.}[!.,!..]*', GLOB_BRACE) ?: [] as $path) {
        is_dir($path) ? removeDir($path) : @unlink($path);
    }
    @rmdir($dir);
}

$results = [];
foreach ($groups as $group) {
    echo "\n#### {$group['name']} (port {$group['port']}, fresh DB)\n";
    [$server, $dbDir, $serverEnv] = startServer($root, $group['port'], $group['env']);
    foreach ($group['scripts'] as $script) {
        $name = array_shift($script);
        echo "\n## $name\n";
        $command = array_merge([PHP_BINARY, __DIR__ . DIRECTORY_SEPARATOR . $name, "http://127.0.0.1:{$group['port']}"], $script);
        $child = proc_open($command, [1 => STDOUT, 2 => STDERR], $childPipes, $root, array_merge(getenv(), $serverEnv));
        $results[$name] = is_resource($child) ? proc_close($child) : 1;
    }
    proc_terminate($server);
    proc_close($server);
    removeDir($dbDir);
}

echo "\n#### Summary\n";
$failed = array_keys(array_filter($results, static fn (int $code): bool => $code !== 0));
foreach ($results as $name => $code) {
    echo ($code === 0 ? '  [GREEN] ' : '  [RED]   ') . $name . "\n";
}
echo count($failed) . ' of ' . count($results) . " suite(s) failed.\n";
echo $failed === [] ? "NET RUN VERDICT: GREEN\n" : "NET RUN VERDICT: RED\n";
exit($failed === [] ? 0 : 1);
