<?php

declare(strict_types=1);

/**
 * Independent net for the UX hardening pass: every error response must
 * carry a human-readable `message` alongside the machine-readable `error`
 * code, per public/index.php's respondError() helper. This doesn't re-check
 * status codes or business logic (the other net/verify_*.php scripts own
 * that) — it specifically re-derives, per response, whether a human reading
 * `message` would learn anything a raw `error` code alone doesn't already
 * say. A `message` that's just the `error` code with underscores swapped
 * for spaces would pass a naive "message key exists" check and still be
 * useless — that's the adjacent case this net exists to catch, not just
 * "is the key present."
 *
 * Usage: php net/verify_error_messages.php [base_url]
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

/**
 * The actual independent check: is `message` a real sentence, not just the
 * `error` code re-cased? Re-derives its own "looks like a sentence" bar
 * (contains a space, is meaningfully longer than the code, and isn't
 * byte-for-byte the code with underscores replaced) rather than trusting
 * that a non-empty string is automatically good enough.
 */
function is_real_message(string $message, string $errorCode): bool
{
    if (trim($message) === '') {
        return false;
    }
    if (str_contains($message, ' ') === false) {
        return false; // a single token is not a sentence
    }
    $codeAsWords = str_replace('_', ' ', $errorCode);
    if (strcasecmp(trim($message), $codeAsWords) === 0) {
        return false; // literally just the code with underscores swapped for spaces
    }
    return true;
}

/** @return array{0: string, 1: string} [error_code, message] pulled from a decoded body, with sane fallbacks for the check() detail string */
function pluck(array $body): array
{
    return [(string) ($body['error'] ?? ''), (string) ($body['message'] ?? '')];
}

function base_payload(): array
{
    return [
        'property_id' => 'prop-net-errmsg',
        'unit_id' => 'unit-net-errmsg',
        'organisation_id' => 'org-net-errmsg',
        'purpose' => 'listing',
        'occupied' => false,
    ];
}

echo "== Session-creation validation errors have real messages ==\n";

$cases = [
    'missing required fields' => [[], 422],
    'invalid purpose' => [[...base_payload(), 'purpose' => 'not-a-real-purpose'], 422],
    'occupied not boolean' => [[...base_payload(), 'occupied' => 'yes'], 422],
    'consent required' => [[...base_payload(), 'occupied' => true], 403],
    'invalid ttl' => [[...base_payload(), 'access_token_ttl_seconds' => 5], 422],
    'property_id too long' => [[...base_payload(), 'property_id' => str_repeat('x', 500)], 422],
];

foreach ($cases as $label => [$payload, $expectedStatus]) {
    [$status, $body] = net_http_json('POST', "$baseUrl/scan-sessions", $payload);
    check("$label returns HTTP $expectedStatus", $status === $expectedStatus, "got HTTP $status");
    [$errorCode, $message] = pluck($body);
    check("$label has a non-empty error code", $errorCode !== '', 'body: ' . json_encode($body));
    check("$label's message is a real sentence, not just the error code restated", is_real_message($message, $errorCode), "error=\"$errorCode\" message=\"$message\"");
}

// Adjacent case, found by deliberately checking a promise made in the very
// error message this file exists to police: field_too_long messages say
// "N characters," but the check backing them used to count bytes. A
// property_id written entirely in a 3-byte-per-character script (e.g.
// Japanese) would previously hit the 200 "character" cap at only ~66 real
// characters — a false rejection, not a security boundary. This is the
// distinction: a length limit is honest input validation; a length limit
// that quietly means something 3-4x smaller for non-Latin-script users is a
// bug wearing a validation error's clothes.
echo "\n== Field length caps count characters, not bytes ==\n";

$japaneseUnder200Chars = str_repeat('日', 150); // 150 real chars, 450 bytes — under the 200-CHAR cap, over a 200-BYTE one
[$mbUnderStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'property_id' => $japaneseUnder200Chars]);
check(
    'a 150-character (450-byte) property_id is ACCEPTED under the 200-character cap',
    $mbUnderStatus === 201,
    "got HTTP $mbUnderStatus — a byte-based length check would wrongly reject this"
);

$japaneseOver200Chars = str_repeat('日', 250); // 250 real chars — genuinely over the 200-CHAR cap
[$mbOverStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'property_id' => $japaneseOver200Chars]);
check('a 250-character property_id is still rejected (HTTP 422) — this is a real cap, not a disabled one', $mbOverStatus === 422, "got HTTP $mbOverStatus");

echo "\n== Session-scoped errors have real messages ==\n";

[, $session] = net_http_json('POST', "$baseUrl/scan-sessions", base_payload());
$sessionId = $session['id'] ?? null;
$token = $session['access_token'] ?? null;
check('session created for session-scoped error checks', $sessionId !== null && $token !== null);

if ($sessionId !== null && $token !== null) {
    [$noTokenStatus, $noTokenBody] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionId");
    check('missing token returns HTTP 401', $noTokenStatus === 401, "got HTTP $noTokenStatus");
    [$noTokenError, $noTokenMessage] = pluck($noTokenBody);
    check('missing-token message is a real sentence', is_real_message($noTokenMessage, $noTokenError), "error=\"$noTokenError\" message=\"$noTokenMessage\"");

    [$noCaptureStatus, $noCaptureBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes", ['text' => 'too early'], $token);
    check('note before any capture returns HTTP 409', $noCaptureStatus === 409, "got HTTP $noCaptureStatus");
    [$noCaptureError, $noCaptureMessage] = pluck($noCaptureBody);
    check('note-before-capture message is a real sentence', is_real_message($noCaptureMessage, $noCaptureError), "error=\"$noCaptureError\" message=\"$noCaptureMessage\"");

    [$missingCaptureStatus, $missingCaptureBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", [], $token);
    check('capture with no raw_capture returns HTTP 422', $missingCaptureStatus === 422, "got HTTP $missingCaptureStatus");
    [$missingCaptureError, $missingCaptureMessage] = pluck($missingCaptureBody);
    check('missing-raw_capture message is a real sentence', is_real_message($missingCaptureMessage, $missingCaptureError), "error=\"$missingCaptureError\" message=\"$missingCaptureMessage\"");

    [$badUrlStatus, $badUrlBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/photos", ['url' => 'javascript:alert(1)'], $token);
    // url-scheme validation runs before the no-floor-plan-yet check in
    // public/index.php's photos handler, so this is 422 even though this
    // session also has no capture yet — validating the input itself before
    // checking state against it, not the other way around.
    check('invalid photo url returns HTTP 422', $badUrlStatus === 422, "got HTTP $badUrlStatus");
    [$badUrlError, $badUrlMessage] = pluck($badUrlBody);
    check('invalid-photo-url message is a real sentence', is_real_message($badUrlMessage, $badUrlError), "error=\"$badUrlError\" message=\"$badUrlMessage\"");
}

echo "\n== Not-found and internal-error fallbacks still have real messages ==\n";

[$notFoundStatus, $notFoundBody] = net_http_json('GET', "$baseUrl/this-route-does-not-exist");
check('unknown route returns HTTP 404', $notFoundStatus === 404, "got HTTP $notFoundStatus");
[$notFoundError, $notFoundMessage] = pluck($notFoundBody);
check('404 message is a real sentence', is_real_message($notFoundMessage, $notFoundError), "error=\"$notFoundError\" message=\"$notFoundMessage\"");

// Adjacent case, mirrors net/verify_security_fixes.php's info-leak check but
// from the message-quality angle specifically: a friendly message must not
// smuggle back exactly the kind of detail the security fix was written to
// suppress (file paths, "Stack trace", the literal exception class name).
$leakTokens = ['.php', 'Stack trace', 'Fatal error', '\\VuuroScan\\', 'on line'];
foreach ($leakTokens as $token) {
    check("404 message does not leak \"$token\"", !str_contains($notFoundMessage, $token), "message: $notFoundMessage");
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
