<?php

declare(strict_types=1);

/**
 * Independent net for privacy/ACL (docs/adr/0003-privacy-acl-session-tokens.md).
 * Same rules as the other net scripts: HTTP only, no importing
 * ScanSessionRepository's authorize/tokenMatches logic — this treats the
 * Scan Service as a black box a real attacker or a real client would see.
 *
 * Usage: php net/verify_phase3_acl.php [base_url]
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

function base_payload(): array
{
    return [
        'property_id' => 'prop-net-acl',
        'unit_id' => 'unit-net-acl',
        'organisation_id' => 'org-net-acl',
        'purpose' => 'listing',
    ];
}

echo "== Consent gate for occupied units ==\n";

[$missingOccupiedStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions", base_payload());
check('creating a session without `occupied` is rejected (HTTP 422)', $missingOccupiedStatus === 422, "got HTTP $missingOccupiedStatus");

[$noConsentStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'occupied' => true]);
check('occupied:true without consent_obtained is rejected (HTTP 403)', $noConsentStatus === 403, "got HTTP $noConsentStatus");

[$falseConsentStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'occupied' => true, 'consent_obtained' => false]);
check('occupied:true with consent_obtained:false is still rejected (HTTP 403)', $falseConsentStatus === 403, "got HTTP $falseConsentStatus");

[$consentedStatus, $consentedSession] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'occupied' => true, 'consent_obtained' => true]);
check('occupied:true with consent_obtained:true succeeds (HTTP 201)', $consentedStatus === 201, "got HTTP $consentedStatus");
check('created session records occupied and consent honestly', ($consentedSession['occupied'] ?? null) === true && ($consentedSession['consent_obtained'] ?? null) === true);

[$unoccupiedStatus, ] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'occupied' => false]);
check('occupied:false needs no consent field at all (HTTP 201)', $unoccupiedStatus === 201, "got HTTP $unoccupiedStatus");

echo "\n== No 'anyone with the link' default: session id alone must not be sufficient ==\n";

[, $sessionA] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'occupied' => false]);
$sessionAId = $sessionA['id'] ?? null;
$sessionAToken = $sessionA['access_token'] ?? null;
check('session A created with a token', $sessionAId !== null && $sessionAToken !== null);

$fixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_single_room.json'), true, 512, JSON_THROW_ON_ERROR);

if ($sessionAId !== null) {
    [$noTokenGet, ] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionAId");
    check('GET with no token at all is rejected (HTTP 401)', $noTokenGet === 401, "got HTTP $noTokenGet");

    [$wrongTokenGet, ] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionAId", null, 'not-a-real-token-00000000-0000-0000-0000-000000000000');
    check('GET with a garbage token is rejected (HTTP 401)', $wrongTokenGet === 401, "got HTTP $wrongTokenGet");

    [$noTokenCapture, ] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionAId/capture", ['raw_capture' => $fixture]);
    check('capture with no token is rejected (HTTP 401)', $noTokenCapture === 401, "got HTTP $noTokenCapture");

    [$correctTokenGet, $correctGetBody] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionAId", null, $sessionAToken);
    check('GET with the correct token succeeds (HTTP 200)', $correctTokenGet === 200, "got HTTP $correctTokenGet");

    // Adjacent case: a second, unrelated session's token must not authorize
    // access to session A. A bug where any well-formed token is accepted
    // (rather than the specific matching one) would still pass every check
    // above and only get caught here.
    [, $sessionB] = net_http_json('POST', "$baseUrl/scan-sessions", [...base_payload(), 'organisation_id' => 'org-net-acl-b', 'occupied' => false]);
    $sessionBToken = $sessionB['access_token'] ?? null;
    if ($sessionBToken !== null) {
        [$crossSessionStatus, ] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionAId", null, $sessionBToken);
        check("session B's token does not authorize access to session A (HTTP 401)", $crossSessionStatus === 401, "got HTTP $crossSessionStatus");
    }
}

echo "\n== Audited access: denied and granted attempts are both logged ==\n";

if ($sessionAId !== null && $sessionAToken !== null) {
    // One deliberate denied attempt, then one granted attempt, then read the log.
    net_http_json('GET', "$baseUrl/scan-sessions/$sessionAId", null, 'another-bad-token');
    net_http_json('GET', "$baseUrl/scan-sessions/$sessionAId", null, $sessionAToken);

    [$logStatus, $logBody] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionAId/access-log", null, $sessionAToken);
    check('access-log endpoint returns HTTP 200 with a valid token', $logStatus === 200, "got HTTP $logStatus");

    $entries = $logBody['access_log'] ?? [];
    $hasDenied = false;
    $hasGranted = false;
    foreach ($entries as $entry) {
        if (($entry['action'] ?? null) === 'read' && ($entry['outcome'] ?? null) === 'denied') {
            $hasDenied = true;
        }
        if (($entry['action'] ?? null) === 'read' && ($entry['outcome'] ?? null) === 'granted') {
            $hasGranted = true;
        }
    }
    check('access log contains at least one denied "read" attempt', $hasDenied, 'no denied entry found — a log that only records successes is not an audit trail');
    check('access log contains at least one granted "read" attempt', $hasGranted);

    [$logWithoutToken, ] = net_http_json('GET', "$baseUrl/scan-sessions/$sessionAId/access-log");
    check('access-log endpoint itself requires a token (HTTP 401 without one)', $logWithoutToken === 401, "got HTTP $logWithoutToken");
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
