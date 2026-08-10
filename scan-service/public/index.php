<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';

use VuuroScan\Adapters\RoomPlanSimulatorAdapter;
use VuuroScan\ScanSessionRepository;
use VuuroScan\Storage\Database;

header('Content-Type: application/json');

function json_body(): array
{
    $raw = file_get_contents('php://input');
    if ($raw === '' || $raw === false) {
        return [];
    }
    $decoded = json_decode($raw, true);
    return is_array($decoded) ? $decoded : [];
}

function respond(int $status, array $body): void
{
    http_response_code($status);
    echo json_encode($body, JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR);
}

function require_fields(array $body, array $fields): ?array
{
    $missing = array_values(array_filter($fields, static fn ($f) => !array_key_exists($f, $body) || $body[$f] === ''));
    return $missing === [] ? null : $missing;
}

$db = Database::connect();
$repo = new ScanSessionRepository($db);

$method = $_SERVER['REQUEST_METHOD'];
$path = rtrim(parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH), '/');

// POST /scan-sessions
if ($method === 'POST' && $path === '/scan-sessions') {
    $body = json_body();
    // Hard constraint #1: identity-native captures. A session cannot be
    // created without property/unit/organisation — no orphan captures by
    // construction, not by convention.
    $missing = require_fields($body, ['property_id', 'unit_id', 'organisation_id', 'purpose']);
    if ($missing !== null) {
        respond(422, ['error' => 'missing_required_fields', 'fields' => $missing]);
        return;
    }
    $validPurposes = ['listing', 'check_in', 'check_out', 'renovation', 'other'];
    if (!in_array($body['purpose'], $validPurposes, true)) {
        respond(422, ['error' => 'invalid_purpose', 'allowed' => $validPurposes]);
        return;
    }

    $session = $repo->create($body['property_id'], $body['unit_id'], $body['organisation_id'], $body['purpose']);
    respond(201, $session);
    return;
}

// POST /scan-sessions/{id}/capture
if ($method === 'POST' && preg_match('#^/scan-sessions/([^/]+)/capture$#', $path, $m)) {
    $sessionId = $m[1];
    $session = $repo->find($sessionId);
    if ($session === null) {
        respond(404, ['error' => 'scan_session_not_found']);
        return;
    }

    $body = json_body();
    if (empty($body['raw_capture']) || !is_array($body['raw_capture'])) {
        respond(422, ['error' => 'missing_raw_capture', 'hint' => 'body must include raw_capture: <RoomPlan-shaped capture JSON>']);
        return;
    }

    $adapter = new RoomPlanSimulatorAdapter();
    try {
        $floorPlan = $adapter->adapt($body['raw_capture'], [
            'scan_session_id' => $session['id'],
            'property_id' => $session['property_id'],
            'unit_id' => $session['unit_id'],
            'organisation_id' => $session['organisation_id'],
            'purpose' => $session['purpose'],
            'capture_provider' => $body['capture_provider'] ?? 'roomplan_simulator_fixture',
        ]);
    } catch (\InvalidArgumentException $e) {
        respond(422, ['error' => 'unprocessable_capture', 'message' => $e->getMessage()]);
        return;
    }

    $repo->saveFloorPlan($session['id'], $floorPlan);
    $repo->markCaptured($session['id']);
    respond(200, $floorPlan);
    return;
}

// GET /scan-sessions/{id}
if ($method === 'GET' && preg_match('#^/scan-sessions/([^/]+)$#', $path, $m)) {
    $sessionId = $m[1];
    $session = $repo->find($sessionId);
    if ($session === null) {
        respond(404, ['error' => 'scan_session_not_found']);
        return;
    }

    $floorPlan = $repo->findFloorPlan($sessionId);
    if ($floorPlan === null) {
        respond(200, ['scan_session_id' => $session['id'], 'status' => $session['status'], 'floor_plan' => null]);
        return;
    }

    respond(200, $floorPlan);
    return;
}

respond(404, ['error' => 'not_found']);
