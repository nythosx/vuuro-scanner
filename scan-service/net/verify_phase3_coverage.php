<?php

declare(strict_types=1);

/**
 * Independent net for coverage/quality scoring. HTTP only, never imports
 * RoomPlanSimulatorAdapter's computeCoverage().
 *
 * Usage: php net/verify_phase3_coverage.php [base_url]
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

function expected_coverage(array $rawCapture): array
{
    $high = 0;
    $medium = 0;
    $low = 0;

    foreach (['floors', 'walls', 'doors', 'windows', 'openings'] as $group) {
        foreach ($rawCapture[$group] ?? [] as $surface) {
            $confidence = $surface['confidence'] ?? 'low';
            if ($confidence === 'high') {
                $high++;
            } elseif ($confidence === 'medium') {
                $medium++;
            } else {
                $low++;
            }
        }
    }

    $total = $high + $medium + $low;
    $points = ($high * 100) + ($medium * 60) + ($low * 20);
    $score = $total > 0 ? (int) round($points / $total) : 0;

    return ['score' => $score, 'high' => $high, 'medium' => $medium, 'low' => $low, 'usable' => $score >= 70];
}

function run_case(string $baseUrl, string $fixturePath, string $label): void
{
    $fixture = json_decode((string) file_get_contents($fixturePath), true, 512, JSON_THROW_ON_ERROR);
    $expected = expected_coverage($fixture);

    [, $session] = net_http_json('POST', "$baseUrl/scan-sessions", [
        'property_id' => 'prop-net-coverage',
        'unit_id' => 'unit-net-coverage',
        'organisation_id' => 'org-net-coverage',
        'purpose' => 'listing',
        'occupied' => false,
    ]);
    $sessionId = $session['id'] ?? null;
    $accessToken = $session['access_token'] ?? null;
    if ($sessionId === null || $accessToken === null) {
        check("$label: session created", false, 'no session id/access_token returned');
        return;
    }

    [, $floorPlan] = net_http_json('POST', "$baseUrl/scan-sessions/$sessionId/capture", ['raw_capture' => $fixture], $accessToken);
    $coverage = $floorPlan['rooms'][0]['coverage'] ?? null;
    check("$label: coverage object present", $coverage !== null);
    if ($coverage === null) {
        return;
    }

    check("$label: score matches independent aggregation ({$expected['score']})",
        ($coverage['score'] ?? null) === $expected['score'],
        'API=' . ($coverage['score'] ?? 'null') . " expected={$expected['score']}");

    check("$label: usable matches the 70-point threshold applied independently",
        ($coverage['usable'] ?? null) === $expected['usable']);

    check("$label: confidence_counts matches independent tally",
        ($coverage['confidence_counts'] ?? null) === ['high' => $expected['high'], 'medium' => $expected['medium'], 'low' => $expected['low']]);

    if ($expected['usable']) {
        // Note: `?? 'not-null'` would be wrong here — the null-coalescing
        // operator treats an actual null value the same as a missing key,
        // so it can't distinguish "message is honestly null" from "message
        // key is absent." Check the key's actual value directly instead.
        check("$label: message is null when usable", array_key_exists('message', $coverage) && $coverage['message'] === null);
    } else {
        check("$label: message is a non-empty string when not usable", is_string($coverage['message'] ?? null) && $coverage['message'] !== '');
    }
}

echo "== Coverage: mostly-high-confidence fixture scores high and usable ==\n";
run_case($baseUrl, __DIR__ . '/../fixtures/roomplan_captured_room_single_room.json', 'single_room');

echo "\n== Adversarial: floor is high confidence but the room overall is not ==\n";
run_case($baseUrl, __DIR__ . '/../fixtures/roomplan_captured_room_low_confidence_adversarial.json', 'low_confidence');

echo "\n== Aggregate confidence differs from a single surface's confidence ==\n";
$lowConfFixture = json_decode((string) file_get_contents(__DIR__ . '/../fixtures/roomplan_captured_room_low_confidence_adversarial.json'), true, 512, JSON_THROW_ON_ERROR);
check('low_confidence fixture\'s floor surface is itself high confidence (the trap)',
    ($lowConfFixture['floors'][0]['confidence'] ?? null) === 'high');

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
