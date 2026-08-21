<?php

declare(strict_types=1);

/**
 * Independent net for one specific finding: the up-to-8MB php://input read
 * that runs for EVERY POST request — before any route match, any session
 * lookup, any auth check, even before create_session's own rate limit —
 * had no rate limit of its own. Confirmed live before the fix: 10
 * back-to-back 1MB POSTs to a nonexistent, unauthenticated path were each
 * fully read into memory ahead of their 404, with nothing throttling that
 * anywhere. Fixed with a generic per-IP limit (500/300s) checked BEFORE the
 * read, in public/index.php.
 *
 * Deliberately its OWN script, run against its OWN fresh server/DB, NOT
 * chained into the regular 8-script net suite: proving the 429 fires means
 * driving the exact bucket this check protects (clientIp():post_body_read)
 * past its ceiling, which is a global-per-IP bucket with no path or session
 * in its key. Doing that inside the shared suite would block every OTHER
 * script's POSTs (session creation, capture, ...) sharing 127.0.0.1 for the
 * rest of the 300s window — the same class of cross-script rate-limit
 * collision already hit once this session with verify_enterprise_hardening
 * ordering, just worse here since this bucket is not session- or
 * route-scoped. Run this alone, against a server on a fresh DB:
 *
 *   php net/verify_post_body_read_rate_limit.php http://127.0.0.1:9499
 *
 * Same rules as every other net script — HTTP only, never imports
 * ScanSessionRepository/index.php.
 */

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

$body = str_repeat('x', 100_000); // 100KB — small enough to run 500+ times quickly
$sawThrottle = false;
$firstThrottleAt = null;
for ($i = 0; $i < 520; $i++) {
    [$status, ] = net_http_raw_literal('POST', "$baseUrl/totally-bogus-unauthenticated-path", $body);
    if ($status === 429) {
        $sawThrottle = true;
        $firstThrottleAt = $i + 1;
        break;
    }
    // Every response before the throttle kicks in must still be a clean
    // 404 (bogus path, no route matches) — not a crash, not an auth error,
    // proving the limiter sits ahead of routing/auth, not tangled with it.
    if ($status !== 404) {
        check("call $i got a 404 (bogus path) before any throttle", false, "got HTTP $status instead");
        break;
    }
}
check(
    'repeated POSTs to a nonexistent, unauthenticated path eventually hit HTTP 429',
    $sawThrottle,
    'never saw a 429 across 520 rapid POSTs'
);
if ($sawThrottle) {
    check(
        'the throttle fires at or before the documented 500-request ceiling, not unboundedly later',
        $firstThrottleAt <= 501,
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
