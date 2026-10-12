<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';

use VuuroScan\Export\FloorPlanPdfRenderer;
use VuuroScan\ScanComparison;

$failures = [];
$checks = 0;

function sc_check(string $label, bool $pass, string $detail = ''): void
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

function sc_room(string $id, string $label, float $area, ?string $floor = 'Ground', array $objects = []): array
{
    return [
        'room_id' => $id, 'label' => $label, 'floor' => $floor, 'floor_area_m2' => $area, 'perimeter_m' => 14.0,
        'bounding_dimensions_m' => ['width_m' => 4.0, 'length_m' => 3.0], 'confidence' => 'high',
        'outline_m' => [[0, 0], [4, 0], [4, 3], [0, 3]], 'structure_origin_m' => null, 'openings' => [],
        'height_m' => 2.6, 'volume_m3_indicative' => null, 'objects' => $objects, 'room_type' => null,
        'heading_deg' => null, 'coverage' => null,
    ];
}

function sc_object(string $category, ?string $customName = null): array
{
    $object = ['object_id' => bin2hex(random_bytes(4)), 'category' => $category, 'position_m' => [1.0, 1.0], 'dimensions_m' => [1.0, 1.0, 1.0], 'yaw_deg' => 0.0, 'confidence' => 'high'];
    if ($customName !== null) {
        $object['custom_name'] = $customName;
    }
    return $object;
}

function sc_plan(array $rooms, array $notes = [], array $photos = [], string $purpose = 'check_in'): array
{
    return [
        'scan_session_id' => 's', 'property_id' => 'p', 'unit_id' => 'u', 'organisation_id' => 'o',
        'capture_provider' => 'roomplan', 'captured_at' => '2026-10-01T10:00:00+00:00',
        'measurement_basis' => 'indicative_nen2580_inspired', 'purpose' => $purpose,
        'rooms' => $rooms, 'notes' => $notes, 'photos' => $photos,
    ];
}

function sc_by_label(array $entries, string $label): ?array
{
    foreach ($entries as $entry) {
        if (($entry['label'] ?? null) === $label) {
            return $entry;
        }
    }
    return null;
}

$earlier = sc_plan([
    sc_room('in-1', 'Woonkamer', 30.0, 'Ground', [sc_object('sofa'), sc_object('chair'), sc_object('chair'), sc_object('table', 'Eettafel')]),
    sc_room('in-2', 'Slaapkamer één', 12.0, 'First'),
    sc_room('in-3', 'Badkamer', 6.0, 'First'),
    sc_room('in-4', 'Berging', 2.0, 'Ground'),
    sc_room('shared-id', 'Hal', 8.0, 'Ground'),
    sc_room('in-6', 'Zolder', 15.0, 'Attic'),
    sc_room('in-7', 'Kamer', 10.0, 'Ground'),
    sc_room('in-8', 'Kamer', 11.0, 'Ground'),
]);
$later = sc_plan([
    sc_room('out-1', '  woonkamer ', 30.4, 'ground', [sc_object('chair'), sc_object('table', 'eettafel')]),
    sc_room('out-2', 'Slaap kamer één', 10.5, 'First'),
    sc_room('out-3', 'Badkamer', 6.0, 'Ground'),
    sc_room('out-4', 'Berging', 2.11, 'Ground'),
    sc_room('shared-id', 'Entree', 8.2, 'Ground'),
    sc_room('out-6', 'Wasruimte', 4.0, 'Ground'),
    sc_room('out-7', 'Kamer', 10.0, 'Ground'),
], [
    ['note_id' => 'n1', 'text' => 'Kras op de vloer', 'room_id' => 'out-1', 'created_at' => '2026-10-05T10:00:00+00:00', 'tags' => ['wear_and_tear']],
    ['note_id' => 'n2', 'text' => 'Gat in de muur', 'room_id' => 'out-2', 'created_at' => '2026-10-05T10:01:00+00:00', 'tags' => ['damage']],
    ['note_id' => 'n3', 'text' => 'Sleutels ingeleverd', 'room_id' => null, 'created_at' => '2026-10-05T10:02:00+00:00', 'tags' => []],
], [
    ['photo_id' => 'f1', 'url' => '/a.jpg', 'caption' => 'Overzicht', 'room_id' => 'out-1', 'taken_at' => '2026-10-05T10:00:00+00:00', 'tags' => []],
    ['photo_id' => 'f2', 'url' => '/b.jpg', 'caption' => 'Gat', 'room_id' => 'out-2', 'taken_at' => '2026-10-05T10:01:00+00:00', 'tags' => ['damage']],
], 'check_out');

$result = ScanComparison::compare($earlier, $later, 0.5, 5.0);
$rooms = $result['rooms'];

echo "== Matching rooms ==\n";
$hal = sc_by_label($rooms['unchanged'], 'Entree');
sc_check('a room with the same room_id is matched even after a rename', $hal !== null && $hal['matched_by'] === 'room_id' && $hal['earlier_room_id'] === 'shared-id', json_encode($rooms));
$living = sc_by_label($rooms['unchanged'], '  woonkamer ');
sc_check('label and floor match ignoring case and spaces', $living !== null && $living['matched_by'] === 'label_and_floor' && $living['earlier_room_id'] === 'in-1', json_encode($rooms['unchanged']));
sc_check('spaces inside a label are ignored too', (sc_by_label($rooms['changed'], 'Slaap kamer één')['earlier_room_id'] ?? null) === 'in-2');
sc_check('the same label on another floor is not matched', sc_by_label($rooms['added'], 'Badkamer') !== null && sc_by_label($rooms['not_matched'], 'Badkamer') !== null);
sc_check('two earlier rooms with one label pair with one later room only', count(array_filter($rooms['unchanged'], static fn (array $r) => $r['label'] === 'Kamer')) === 1 && sc_by_label($rooms['not_matched'], 'Kamer')['room_id'] === 'in-8', json_encode($rooms['not_matched']));

echo "\n== Added, changed and not matched ==\n";
sc_check('a room only in the later scan is added', sc_by_label($rooms['added'], 'Wasruimte')['area_m2'] === 4.0, json_encode($rooms['added']));
sc_check('a room only in the earlier scan is not matched, never removed', sc_by_label($rooms['not_matched'], 'Zolder') !== null && !array_key_exists('removed', $rooms));
$bedroom = sc_by_label($rooms['changed'], 'Slaap kamer één');
sc_check('a room 1.5 m2 smaller is changed', $bedroom !== null && $bedroom['area_change_m2'] === -1.5 && $bedroom['area_change_percent'] === -12.5, json_encode($bedroom));
sc_check('0.4 m2 on a 30 m2 room stays below both thresholds', $living['area_change_m2'] === 0.4 && $living['area_change_percent'] === 1.3, json_encode($living));
$storage = sc_by_label($rooms['changed'], 'Berging');
sc_check('0.11 m2 on a 2 m2 room is changed by the percent rule alone', $storage !== null && $storage['area_change_percent'] === 5.5, json_encode($rooms['changed']));
sc_check('exactly on a threshold is not a change', ScanComparison::compare(sc_plan([sc_room('a', 'X', 10.0)]), sc_plan([sc_room('a', 'X', 10.5)]), 0.5, 5.0)['rooms']['changed'] === []);
sc_check('a stricter threshold makes the hall change', sc_by_label(ScanComparison::compare($earlier, $later, 0.1, 1.0)['rooms']['changed'], 'Entree') !== null);
sc_check('a wider threshold hides the storage change', sc_by_label(ScanComparison::compare($earlier, $later, 0.5, 10.0)['rooms']['changed'], 'Berging') === null);
sc_check('the wording is indicative', $result['measurement_basis'] === 'indicative' && $result['thresholds'] === ['area_change_m2' => 0.5, 'area_change_percent' => 5.0]);

echo "\n== Objects ==\n";
$gone = $result['objects_gone'];
$goneNames = array_map(static fn (array $o) => $o['name'] . ' x' . $o['count'], $gone);
sc_check('a sofa and one of two chairs are missing in the living room', $goneNames === ['sofa x1', 'chair x1'], json_encode($gone));
sc_check('a renamed object is matched by its name, ignoring case', !in_array('Eettafel x1', $goneNames, true));
sc_check('missing objects name the later room', ($gone[0]['later_room_id'] ?? null) === 'out-1' && ($gone[0]['room_label'] ?? null) === '  woonkamer ');
sc_check('unmatched rooms do not report missing objects', count($gone) === 2);

echo "\n== Notes and photos ==\n";
sc_check('damage notes come first', array_column($result['notes_added'], 'note_id') === ['n2', 'n1', 'n3'], json_encode(array_column($result['notes_added'], 'note_id')));
sc_check('notes name their room in the later scan', $result['notes_added'][0]['room_label'] === 'Slaap kamer één' && $result['notes_added'][2]['room_label'] === null);
sc_check('damage photos come first', array_column($result['photos_added'], 'photo_id') === ['f2', 'f1']);
sc_check('the earlier scan adds nothing', ScanComparison::compare($later, $earlier, 0.5, 5.0)['notes_added'] === []);

echo "\n== PDF section ==\n";
$changes = ['earlier' => ['id' => 'e', 'purpose' => 'check_in', 'created_at' => '2026-10-01T10:00:00+00:00', 'captured_at' => '2026-10-01T10:00:00+00:00'], ...$result];
$pdf = new FloorPlanPdfRenderer();
$sectionLines = array_column((new ReflectionMethod($pdf, 'changesLines'))->invoke($pdf, $changes, 'metric'), 'text');
$section = implode("\n", $sectionLines);
sc_check('the section is called Changes since check-in', in_array('Changes since check-in', $sectionLines, true));
sc_check('the section says indicative and never certified', str_contains($section, 'Indicative') && !str_contains(strtolower($section), 'certified'));
sc_check('the section lists the changed bedroom with its areas', str_contains($section, 'Slaap kamer één (First): 12.00 sqm -> 10.50 sqm (-1.50 sqm, -12.5%)'), $section);
sc_check('the section says not matched rooms were not removed', str_contains($section, 'It does not mean the room was removed.'));
sc_check('the section lists the damage note first', strpos($section, 'Gat in de muur') < strpos($section, 'Kras op de vloer'));
sc_check('no line in the section is wider than a page line', max(array_map('mb_strlen', $sectionLines)) <= 110, (string) max(array_map('mb_strlen', $sectionLines)));
$quiet = ScanComparison::compare(sc_plan([sc_room('a', 'X', 10.0)]), sc_plan([sc_room('b', 'x', 10.1)]), 0.5, 5.0);
$quietText = implode("\n", array_column((new ReflectionMethod($pdf, 'changesLines'))->invoke($pdf, ['earlier' => ['purpose' => 'listing', 'created_at' => '2026-10-01T10:00:00+00:00'], ...$quiet], 'metric'), 'text'));
sc_check('a scan without changes says so', str_contains($quietText, 'Changes since the earlier scan') && str_contains($quietText, 'No room changed above the threshold'), $quietText);

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
