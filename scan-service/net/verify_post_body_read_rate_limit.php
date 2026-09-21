<?php

declare(strict_types=1);

require_once __DIR__ . '/lib/http_client.php';

$baseUrl = $argv[1] ?? 'http://127.0.0.1:9499';
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

echo "== The global POST body-read step is rate-limited per IP, independent of path/auth validity ==\n";

$body = str_repeat('x', 100_000); // 100KB — small enough to run thousands of times quickly
$sawThrottle = false;
$firstThrottleAt = null;
for ($i = 0; $i < 4050; $i++) {
    [$status, ] = net_http_raw_literal('POST', "$baseUrl/totally-bogus-unauthenticated-path", $body);
    if ($status === 429) {
        $sawThrottle = true;
        $firstThrottleAt = $i + 1;
        break;
    }

    if ($status !== 404) {
        check("call $i got a 404 (bogus path) before any throttle", false, "got HTTP $status instead");
        break;
    }
}
check(
    'repeated POSTs to a nonexistent, unauthenticated path eventually hit HTTP 429',
    $sawThrottle,
    'never saw a 429 across 4050 rapid POSTs'
);
if ($sawThrottle) {
    check(
        'the throttle fires at or before the documented 4000-request ceiling, not unboundedly later',
        $firstThrottleAt <= 4001,
        "first 429 arrived at call $firstThrottleAt"
    );
}

echo "\n" . count($failures) . " failure(s) out of $checks check(s).\n";
if ($failures !== []) {
    fwrite(STDERR, "\nNET VERDICT: RED\n");
    foreach ($failures as $f) {
        fwrite(STDERR, " - $f\n");
    }
    exit(1);
}
fwrite(STDERR, "\nNET VERDICT: GREEN\n");
