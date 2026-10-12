<?php

declare(strict_types=1);

require_once __DIR__ . '/../../src/autoload.php';

use VuuroScan\Adapters\RoomPlanSimulatorAdapter;

function scenario_polygon_area(array $outline): float
{
    $n = count($outline);
    $sum = 0.0;
    for ($i = 0; $i < $n; $i++) {
        [$x1, $z1] = $outline[$i];
        [$x2, $z2] = $outline[($i + 1) % $n];
        $sum += $x1 * $z2 - $x2 * $z1;
    }
    return abs($sum) / 2.0;
}

function scenario_polygon_perimeter(array $outline): float
{
    $n = count($outline);
    $sum = 0.0;
    for ($i = 0; $i < $n; $i++) {
        [$x1, $z1] = $outline[$i];
        [$x2, $z2] = $outline[($i + 1) % $n];
        $sum += sqrt(($x2 - $x1) ** 2 + ($z2 - $z1) ** 2);
    }
    return $sum;
}

function scenario_room(
    string $roomId,
    string $label,
    array $outline,
    array $origin,
    ?string $floor,
    ?string $groupId,
    ?string $joinedToGroupId,
    array $openings = [],
    array $objects = []
): array {
    $outline = array_map(static fn (array $p) => [(float) $p[0] - (float) $origin[0], (float) $p[1] - (float) $origin[1]], $outline);
    $xs = array_column($outline, 0);
    $zs = array_column($outline, 1);
    return [
        'room_id' => $roomId,
        'label' => $label,
        'floor_area_m2' => round(scenario_polygon_area($outline), 2),
        'perimeter_m' => round(scenario_polygon_perimeter($outline), 2),
        'bounding_dimensions_m' => [
            'width_m' => round(max($xs) - min($xs), 2),
            'length_m' => round(max($zs) - min($zs), 2),
        ],
        'confidence' => 'high',
        'outline_m' => array_map(static fn (array $p) => [round($p[0], 3), round($p[1], 3)], $outline),
        'coverage' => null,
        'openings' => $openings,
        'height_m' => 2.6,
        'volume_m3_indicative' => round(scenario_polygon_area($outline) * 2.6, 2),
        'objects' => $objects,
        'structure_origin_m' => [round($origin[0], 4), round($origin[1], 4)],
        'capture_group_id' => $groupId,
        'joined_to_group_id' => $joinedToGroupId,
        'story' => null,
        'floor' => $floor,
        'heading_deg' => null,
        'room_type' => null,
        'walk_path_m' => [],
    ];
}

function scenario_plan(array $rooms, array $notes = [], array $photos = []): array
{
    return [
        'scan_session_id' => 'scenario',
        'property_id' => 'prop-scenario',
        'unit_id' => 'unit-scenario',
        'organisation_id' => 'org-scenario',
        'purpose' => 'listing',
        'capture_provider' => 'scenario',
        'captured_at' => gmdate('c'),
        'measurement_basis' => 'indicative_nen2580_inspired',
        'rooms' => $rooms,
        'photos' => $photos,
        'notes' => $notes,
        'capture_location' => null,
    ];
}

function scenario_adapter_rooms(string $fixtureFile, string $floor, ?string $groupId = null, ?array $origin = null): array
{
    $raw = json_decode((string) file_get_contents(__DIR__ . '/../../fixtures/' . $fixtureFile), true, 512, JSON_THROW_ON_ERROR);
    if ($groupId !== null) {
        $raw['capture_group_id'] = $groupId;
    }
    if ($origin !== null) {
        $raw['structure_origin_m'] = $origin;
    }
    $identity = [
        'scan_session_id' => 'scenario',
        'property_id' => 'prop-scenario',
        'unit_id' => 'unit-scenario',
        'organisation_id' => 'org-scenario',
        'purpose' => 'listing',
        'floor' => $floor,
    ];
    return (new RoomPlanSimulatorAdapter())->adapt($raw, $identity)['rooms'];
}

function scenario_device_openings(string $floor = 'Ground'): array
{
    return [
        'opening_id' => 'dev-door',
        'category' => 'door',
        'position_m' => [1.2, 4.0],
        'width_m' => 0.85,
        'confidence' => 'high',
    ];
}

function render_scenarios(): array
{
    $scenarios = [];

    $deviceRooms = scenario_adapter_rooms('roomplan_captured_room_device_openings.json', 'Ground');
    $scenarios['device_single'] = ['plan' => scenario_plan($deviceRooms), 'layout' => 'auto', 'room_id' => null];

    $lshapedRooms = scenario_adapter_rooms('roomplan_captured_room_lshaped_adversarial.json', 'Ground');
    $scenarios['lshaped'] = ['plan' => scenario_plan($lshapedRooms), 'layout' => 'auto', 'room_id' => null];

    $unitRooms = [];
    $unitRoomShapes = [
        ['room-01-unit', 'Living', [[0.0, 0.0], [4.0, 0.0], [4.0, 4.0], [0.0, 4.0]], [0.0, 0.0]],
        ['room-02-unit', 'Kitchen', [[4.0, 0.0], [7.0, 0.0], [7.0, 3.0], [4.0, 3.0]], [4.0, 0.0]],
        ['room-03-unit', 'Hall', [[0.0, 4.0], [2.0, 4.0], [2.0, 6.0], [0.0, 6.0]], [0.0, 4.0]],
        ['room-04-unit', 'Bedroom', [[4.0, 3.0], [7.0, 3.0], [7.0, 6.0], [4.0, 6.0]], [4.0, 3.0]],
        ['room-05-unit', 'Bath', [[2.0, 4.0], [4.0, 4.0], [4.0, 6.0], [2.0, 6.0]], [2.0, 4.0]],
    ];
    foreach ($unitRoomShapes as [$id, $label, $outline, $origin]) {
        $unitRooms[] = scenario_room($id, $label, $outline, $origin, 'Ground', 'unit-g1', null);
    }
    $scenarios['whole_unit'] = ['plan' => scenario_plan($unitRooms), 'layout' => 'auto', 'room_id' => null, 'sections' => 1];

    $continueRooms = [
        scenario_room('room-01-cont', 'Living', [[0.0, 0.0], [4.0, 0.0], [4.0, 4.0], [0.0, 4.0]], [0.0, 0.0], 'Ground', 'cont-g1', null),
        scenario_room('room-02-cont', 'Kitchen', [[4.0, 0.0], [7.0, 0.0], [7.0, 3.0], [4.0, 3.0]], [4.0, 0.0], 'Ground', 'cont-g1', null),
        scenario_room('room-03-cont', 'Study', [[8.0, 0.0], [11.0, 0.0], [11.0, 3.0], [8.0, 3.0]], [8.0, 0.0], 'Ground', 'cont-g2', null),
    ];
    $scenarios['continued_not_joined'] = ['plan' => scenario_plan($continueRooms), 'layout' => 'auto', 'room_id' => null, 'sections' => 2];

    $joinedRooms = [
        scenario_room('room-01-join', 'Living', [[0.0, 0.0], [4.0, 0.0], [4.0, 4.0], [0.0, 4.0]], [0.0, 0.0], 'Ground', 'join-g1', null),
        scenario_room('room-02-join', 'Kitchen', [[4.0, 0.0], [7.0, 0.0], [7.0, 3.0], [4.0, 3.0]], [4.0, 0.0], 'Ground', 'join-g1', null),
        scenario_room('room-03-join', 'Study', [[7.0, 0.0], [10.0, 0.0], [10.0, 3.0], [7.0, 3.0]], [7.0, 0.0], 'Ground', 'join-g2', 'join-g1'),
    ];
    $scenarios['joined'] = ['plan' => scenario_plan($joinedRooms), 'layout' => 'auto', 'room_id' => null, 'sections' => 1];

    $twoFloorRooms = [
        scenario_room('room-01-floors', 'Living', [[0.0, 0.0], [4.0, 0.0], [4.0, 4.0], [0.0, 4.0]], [0.0, 0.0], 'Ground', 'floors-g1', null),
        scenario_room('room-02-floors', 'Attic room', [[0.0, 0.0], [4.0, 0.0], [4.0, 4.0], [0.0, 4.0]], [0.0, 0.0], 'Attic', 'floors-g2', null),
    ];
    $scenarios['two_floors'] = ['plan' => scenario_plan($twoFloorRooms), 'layout' => 'auto', 'room_id' => null, 'sections' => 2];

    $floorlessRooms = [
        scenario_room('room-01-floorless', 'Unknown room', [[0.0, 0.0], [4.0, 0.0], [4.0, 4.0], [0.0, 4.0]], [0.0, 0.0], null, 'floorless-g1', null),
    ];
    $scenarios['floorless_legacy'] = ['plan' => scenario_plan($floorlessRooms), 'layout' => 'auto', 'room_id' => null, 'sections' => 1];

    $tileRooms = [
        scenario_room('room-01-tiles', 'Living', [[0.0, 0.0], [4.0, 0.0], [4.0, 4.0], [0.0, 4.0]], [0.0, 0.0], 'Ground', null, null),
        scenario_room('room-02-tiles', 'Kitchen', [[0.0, 0.0], [3.0, 0.0], [3.0, 2.0], [0.0, 2.0]], [0.0, 0.0], 'Ground', null, null),
    ];
    $scenarios['tiles'] = ['plan' => scenario_plan($tileRooms), 'layout' => 'tiles', 'room_id' => null];

    $placedA = scenario_adapter_rooms('roomplan_captured_room_device_openings.json', 'Ground', 'place-A', [0.0, 0.0])[0];
    $placedB = $placedA;
    $placedB['room_id'] = 'room-02-placed';
    $placedB['label'] = 'Room 2';
    $placedB['capture_group_id'] = 'place-B';
    $placedB = \VuuroScan\GroupPlacement::transformRoom($placedB, 90.0, 9.0, 0.0);
    $placedB['joined_to_group_id'] = 'place-A';
    $scenarios['placed_by_hand'] = ['plan' => scenario_plan([$placedA, $placedB]), 'layout' => 'auto', 'room_id' => null, 'sections' => 1];

    return $scenarios;
}
