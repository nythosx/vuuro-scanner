<?php

declare(strict_types=1);

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

function is_real_message(string $message, string $errorCode): bool
{
    if (trim($message) === '') {
        return false;
    }
    if (str_contains($message, ' ') === false) {
        return false;
    }
    $codeAsWords = str_replace('_', ' ', $errorCode);
    if (strcasecmp(trim($message), $codeAsWords) === 0) {
        return false;
    }
    return true;
}

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
    'property_id as a number, not a string' => [[...base_payload(), 'property_id' => 12345], 422],
    'unit_id as an array, not a string' => [[...base_payload(), 'unit_id' => []], 422],
    'organisation_id as a boolean, not a string' => [[...base_payload(), 'organisation_id' => true], 422],
];

foreach ($cases as $label => [$payload, $expectedStatus]) {
    [$status, $body] = net_http_json('POST', "$baseUrl/scan-sessions", $payload);
    check("$label returns HTTP $expectedStatus", $status === $expectedStatus, "got HTTP $status");
    [$errorCode, $message] = pluck($body);
    check("$label has a non-empty error code", $errorCode !== '', 'body: ' . json_encode($body));
    check("$label's message is a real sentence, not just the error code restated", is_real_message($message, $errorCode), "error=\"$errorCode\" message=\"$message\"");
}

echo "\n== Field length caps count characters, not bytes ==\n";

$japaneseUnder200Chars = str_repeat('日', 150);
[$mbUnderStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'property_id' => $japaneseUnder200Chars]);
check(
    'a 150-character (450-byte) property_id is ACCEPTED under the 200-character cap',
    $mbUnderStatus === 201,
    "got HTTP $mbUnderStatus — a byte-based length check would wrongly reject this"
);

$japaneseOver200Chars = str_repeat('日', 250);
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
    check('invalid photo url returns HTTP 422', $badUrlStatus === 422, "got HTTP $badUrlStatus");
    [$badUrlError, $badUrlMessage] = pluck($badUrlBody);
    check('invalid-photo-url message is a real sentence', is_real_message($badUrlMessage, $badUrlError), "error=\"$badUrlError\" message=\"$badUrlMessage\"");

    [$nonStringUrlStatus, $nonStringUrlBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/photos", ['url' => ['not', 'a', 'string']], $token);
    check('a non-string photo url returns HTTP 422, not a 500 crash', $nonStringUrlStatus === 422, "got HTTP $nonStringUrlStatus");
    [$nonStringUrlError, $nonStringUrlMessage] = pluck($nonStringUrlBody);
    check('non-string-url message is a real sentence', is_real_message($nonStringUrlMessage, $nonStringUrlError), "error=\"$nonStringUrlError\" message=\"$nonStringUrlMessage\"");

    [$nonStringCaptionStatus, $nonStringCaptionBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/photos", ['url' => 'https://example.com/x.jpg', 'caption' => 42], $token);
    check('a non-string photo caption returns HTTP 422, not silently stored', $nonStringCaptionStatus === 422, "got HTTP $nonStringCaptionStatus");
    [$nonStringCaptionError, $nonStringCaptionMessage] = pluck($nonStringCaptionBody);
    check('non-string-caption message is a real sentence', is_real_message($nonStringCaptionMessage, $nonStringCaptionError), "error=\"$nonStringCaptionError\" message=\"$nonStringCaptionMessage\"");

    [$nonStringTextStatus, $nonStringTextBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/notes", ['text' => ['not', 'a', 'string']], $token);
    check('a non-string note text returns HTTP 422, not silently stored', $nonStringTextStatus === 422, "got HTTP $nonStringTextStatus");
    [$nonStringTextError, $nonStringTextMessage] = pluck($nonStringTextBody);
    check('non-string-text message is a real sentence', is_real_message($nonStringTextMessage, $nonStringTextError), "error=\"$nonStringTextError\" message=\"$nonStringTextMessage\"");

    [$nonStringTakenAtStatus, $nonStringTakenAtBody] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/photos", ['url' => 'https://example.com/x.jpg', 'taken_at' => 12345], $token);
    check('a non-string photo taken_at returns HTTP 422, not silently stored', $nonStringTakenAtStatus === 422, "got HTTP $nonStringTakenAtStatus");
    [$nonStringTakenAtError, $nonStringTakenAtMessage] = pluck($nonStringTakenAtBody);
    check('non-string-taken_at message is a real sentence', is_real_message($nonStringTakenAtMessage, $nonStringTakenAtError), "error=\"$nonStringTakenAtError\" message=\"$nonStringTakenAtMessage\"");

    [, $captureProviderSession] = net_http_json('POST', "$baseUrl/scan-sessions", base_payload());
    $singleRoomFixture = ['floors' => [['identifier' => 'f', 'polygonCorners' => [[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]]]]];
    [$nonStringProviderStatus, $nonStringProviderBody] = net_http_json('POST', "$baseUrl/scan-sessions/{$captureProviderSession['id']}/capture", [
        'raw_capture' => $singleRoomFixture,
        'capture_provider' => ['not', 'a', 'string'],
    ], $captureProviderSession['access_token']);
    check('a non-string capture_provider returns HTTP 422, not a silently corrupted record', $nonStringProviderStatus === 422, "got HTTP $nonStringProviderStatus");
    [$nonStringProviderError, $nonStringProviderMessage] = pluck($nonStringProviderBody);
    check('non-string-capture_provider message is a real sentence', is_real_message($nonStringProviderMessage, $nonStringProviderError), "error=\"$nonStringProviderError\" message=\"$nonStringProviderMessage\"");

    [, $identifierSession] = net_http_json('POST', "$baseUrl/scan-sessions", base_payload());
    [$nonStringIdentifierStatus, $nonStringIdentifierBody] = net_http_json('POST', "$baseUrl/scan-sessions/{$identifierSession['id']}/capture", [
        'raw_capture' => ['floors' => [['identifier' => ['not', 'a', 'string'], 'polygonCorners' => [[0, 0, 0], [2, 0, 0], [2, 0, 2], [0, 0, 2]]]]],
    ], $identifierSession['access_token']);
    check('a non-string floors[].identifier returns HTTP 422, not a silently corrupted room_id', $nonStringIdentifierStatus === 422, "got HTTP $nonStringIdentifierStatus");
    [$nonStringIdentifierError, $nonStringIdentifierMessage] = pluck($nonStringIdentifierBody);
    check('non-string-identifier message is a real sentence', is_real_message($nonStringIdentifierMessage, $nonStringIdentifierError), "error=\"$nonStringIdentifierError\" message=\"$nonStringIdentifierMessage\"");

    [, $idemLengthSession] = net_http_json('POST', "$baseUrl/scan-sessions", base_payload());
    [$tooLongKeyStatus, $tooLongKeyBody] = net_http_json_ex('POST', "$baseUrl/scan-sessions/{$idemLengthSession['id']}/capture", [
        'raw_capture' => $singleRoomFixture,
    ], $idemLengthSession['access_token'], ['Idempotency-Key' => str_repeat('k', 201)]);
    check('an Idempotency-Key over 200 characters returns HTTP 422, not silently stored', $tooLongKeyStatus === 422, "got HTTP $tooLongKeyStatus");
    [$tooLongKeyError, $tooLongKeyMessage] = pluck($tooLongKeyBody);
    check('too-long-Idempotency-Key message is a real sentence', is_real_message($tooLongKeyMessage, $tooLongKeyError), "error=\"$tooLongKeyError\" message=\"$tooLongKeyMessage\"");

    [$exactlyMaxKeyStatus, ] = net_http_json_ex('POST', "$baseUrl/scan-sessions/{$idemLengthSession['id']}/capture", [
        'raw_capture' => $singleRoomFixture,
    ], $idemLengthSession['access_token'], ['Idempotency-Key' => str_repeat('k', 200)]);
    check('an Idempotency-Key of exactly 200 characters is NOT rejected', $exactlyMaxKeyStatus === 200, "got HTTP $exactlyMaxKeyStatus");
}

echo "\n== Not-found and internal-error fallbacks still have real messages ==\n";

[$notFoundStatus, $notFoundBody] = net_http_json('GET', "$baseUrl/this-route-does-not-exist");
check('unknown route returns HTTP 404', $notFoundStatus === 404, "got HTTP $notFoundStatus");
[$notFoundError, $notFoundMessage] = pluck($notFoundBody);
check('404 message is a real sentence', is_real_message($notFoundMessage, $notFoundError), "error=\"$notFoundError\" message=\"$notFoundMessage\"");

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