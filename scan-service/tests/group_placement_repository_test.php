<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';

use VuuroScan\Storage\Database;
use VuuroScan\ScanSessionRepository;

$failures = [];
$checks = 0;

function gpr_check(string $label, bool $pass, string $detail = ''): void
{
    global $failures, $checks;
    $checks++;
    if ($pass) {
        echo "  [PASS] $label\n";
    } else {
        $failures[] = "$label - $detail";
        echo "  [FAIL] $label - $detail\n";
    }
}

function gpr_room(string $id, string $group, ?string $floor, array $origin): array
{
    return [
        'room_id' => $id, 'label' => $id, 'floor_area_m2' => 12.0, 'perimeter_m' => 14.0,
        'bounding_dimensions_m' => ['width_m' => 4.0, 'length_m' => 3.0], 'confidence' => 'high',
        'outline_m' => [[0, 0], [4, 0], [4, 3], [0, 3]],
        'coverage' => ['score' => 90, 'confidence_counts' => ['high' => 1, 'medium' => 0, 'low' => 0], 'usable' => true, 'message' => null],
        'openings' => [], 'objects' => [],
        'structure_origin_m' => $origin, 'capture_group_id' => $group, 'floor' => $floor,
    ];
}

function gpr_session(ScanSessionRepository $repo, array $rooms): string
{
    $session = $repo->create('prop-gpr', 'unit-gpr', 'org-gpr', 'listing', false, false);
    $repo->appendCapture($session['id'], [
        'scan_session_id' => $session['id'],
        'property_id' => 'p', 'unit_id' => 'u', 'organisation_id' => 'o',
        'capture_provider' => 'test', 'captured_at' => gmdate('c'),
        'measurement_basis' => 'indicative_nen2580_inspired', 'purpose' => 'listing',
        'rooms' => $rooms, 'photos' => [], 'notes' => [],
    ]);
    return $session['id'];
}

function gpr_room_by_id(array $floorPlan, string $id): array
{
    foreach ($floorPlan['rooms'] as $room) {
        if ($room['room_id'] === $id) {
            return $room;
        }
    }
    return [];
}

function gpr_origin(array $floorPlan, string $id): array
{
    return array_map('floatval', gpr_room_by_id($floorPlan, $id)['structure_origin_m'] ?? []);
}

function gpr_error(callable $fn): ?string
{
    try {
        $fn();
    } catch (\InvalidArgumentException $e) {
        return $e->getMessage();
    }
    return null;
}

$repo = new ScanSessionRepository(Database::connect(':memory:'));

echo "== A group that spans two floors ==\n";
$twoFloors = gpr_session($repo, [
    gpr_room('a-attic', 'walk-A', 'Attic', [0.0, 0.0]),
    gpr_room('a-ground', 'walk-A', 'Ground', [0.0, 0.0]),
    gpr_room('b-ground', 'walk-B', 'Ground', [4.0, 0.0]),
]);
$error = gpr_error(static fn () => $repo->placeGroup($twoFloors, 'walk-A', null, 0.0, [5.0, 0.0]));
gpr_check('placing it without a floor is refused with floor_required', $error === 'floor_required', (string) $error);

$moved = $repo->placeGroup($twoFloors, 'walk-A', null, 0.0, [5.0, 0.0], 'Ground', true);
gpr_check('placing Ground moves the Ground room', gpr_origin($moved, 'a-ground') === [5.0, 0.0], json_encode(gpr_origin($moved, 'a-ground')));
gpr_check('the Attic room of the same group stays where it was', gpr_origin($moved, 'a-attic') === [0.0, 0.0], json_encode(gpr_origin($moved, 'a-attic')));

echo "\n== Joining to a group whose first room is on another floor ==\n";
$joined = null;
$error = gpr_error(static function () use ($repo, $twoFloors, &$joined) {
    $joined = $repo->placeGroup($twoFloors, 'walk-B', 'walk-A', 0.0, [0.0, 0.0], 'Ground', true);
});
gpr_check('the target is looked up on the same floor, not refused as floor_mismatch', $error === null, (string) $error);
gpr_check('the Ground room of B joins A', $joined !== null && (gpr_room_by_id($joined, 'b-ground')['joined_to_group_id'] ?? null) === 'walk-A');

echo "\n== A floor without a name ==\n";
$noName = gpr_session($repo, [
    gpr_room('c-none', 'walk-C', null, [0.0, 0.0]),
    gpr_room('c-attic', 'walk-C', 'Attic', [0.0, 0.0]),
]);
$movedNone = $repo->placeGroup($noName, 'walk-C', null, 0.0, [2.0, 0.0], null, true);
gpr_check('placing the unnamed floor moves only the room without a floor', gpr_origin($movedNone, 'c-none') === [2.0, 0.0], json_encode(gpr_origin($movedNone, 'c-none')));
gpr_check('the Attic room is not moved along', gpr_origin($movedNone, 'c-attic') === [0.0, 0.0], json_encode(gpr_origin($movedNone, 'c-attic')));

echo "\n== Distance to the join target, after the move ==\n";
$far = gpr_session($repo, [
    gpr_room('d-1', 'walk-D', 'Ground', [0.0, 0.0]),
    gpr_room('e-1', 'walk-E', 'Ground', [300.0, 0.0]),
]);
$error = gpr_error(static fn () => $repo->placeGroup($far, 'walk-E', 'walk-D', 0.0, [0.0, 0.0], 'Ground', true));
gpr_check('joining a group that ends up 300 m away is refused', $error === 'group_too_far', (string) $error);
gpr_check('the refused placement is not saved', gpr_origin($repo->findFloorPlan($far), 'e-1') === [300.0, 0.0]);
$error = gpr_error(static fn () => $repo->placeGroup($far, 'walk-E', 'walk-D', 0.0, [-296.0, 0.0], 'Ground', true));
gpr_check('the same group moved next to the target joins fine', $error === null, (string) $error);

echo "\n" . count($failures) . " failure(s) out of $checks check(s).\n";
if ($failures !== []) {
    fwrite(STDERR, "\nTEST VERDICT: RED\n");
    foreach ($failures as $f) {
        fwrite(STDERR, " - $f\n");
    }
    exit(1);
}

echo "\nTEST VERDICT: GREEN\n";
exit(0);
