<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';

use VuuroScan\Export\DollhouseGltfWriter;

$failures = [];
$checks = 0;

function dg_check(string $label, bool $pass, string $detail = ''): void
{
    global $failures, $checks;
    $checks++;
    if ($pass) {
        echo "  [PASS] $label\n";
    } else {
        $failures[] = "$label -- $detail";
        echo "  [FAIL] $label -- $detail\n";
    }
}

function dg_room(string $id, array $outline): array
{
    return [
        'room_id' => $id,
        'label' => $id,
        'floor_area_m2' => 12.0,
        'perimeter_m' => 14.0,
        'bounding_dimensions_m' => ['width_m' => 4.0, 'length_m' => 3.0],
        'confidence' => 'high',
        'outline_m' => $outline,
        'structure_origin_m' => [0.0, 0.0],
        'floor' => 'Ground',
        'height_m' => 2.6,
        'openings' => [],
        'objects' => [],
        'coverage' => null,
    ];
}

function dg_plan(array $rooms): array
{
    return [
        'scan_session_id' => 'dg-test',
        'property_id' => 'p', 'unit_id' => 'u', 'organisation_id' => 'o',
        'capture_provider' => 'test', 'captured_at' => gmdate('c'),
        'measurement_basis' => 'indicative_nen2580_inspired', 'purpose' => 'listing',
        'rooms' => $rooms, 'photos' => [], 'notes' => [],
    ];
}

echo "== A small floor plan produces a parseable GLB ==\n";
$glb = (new DollhouseGltfWriter())->write(dg_plan([
    dg_room('r1', [[0, 0], [4, 0], [4, 3], [0, 3]]),
    dg_room('r2', [[4, 0], [7, 0], [7, 3], [4, 3]]),
]));

dg_check('output is not empty', strlen($glb) > 20, (string) strlen($glb));

$magic = unpack('V', substr($glb, 0, 4))[1];
$version = unpack('V', substr($glb, 4, 4))[1];
$totalLen = unpack('V', substr($glb, 8, 4))[1];
dg_check('GLB magic bytes are 0x46546C67', $magic === 0x46546C67, dechex($magic));
dg_check('GLB version is 2', $version === 2, (string) $version);
dg_check('declared total length matches the actual byte length', $totalLen === strlen($glb), $totalLen . ' vs ' . strlen($glb));
dg_check('total length is 4-byte aligned', $totalLen % 4 === 0);

$offset = 12;
$chunks = [];
while ($offset + 8 <= $totalLen) {
    $chunkLen = unpack('V', substr($glb, $offset, 4))[1];
    $chunkType = unpack('V', substr($glb, $offset + 4, 4))[1];
    $chunks[] = ['len' => $chunkLen, 'type' => $chunkType, 'start' => $offset + 8];
    $offset += 8 + $chunkLen;
}
dg_check('exactly two chunks are present', count($chunks) === 2, (string) count($chunks));
dg_check('first chunk is JSON (0x4E4F534A)', ($chunks[0]['type'] ?? 0) === 0x4E4F534A);
dg_check('second chunk is BIN (0x004E4942)', ($chunks[1]['type'] ?? 0) === 0x004E4942);
dg_check('each chunk starts on a 4-byte boundary', ($chunks[0]['start'] % 4 === 0) && ($chunks[1]['start'] % 4 === 0));
dg_check('each chunk length is 4-byte aligned', ($chunks[0]['len'] % 4 === 0) && ($chunks[1]['len'] % 4 === 0));

echo "\n== JSON chunk is valid and its bufferViews are aligned ==\n";
$json = json_decode(substr($glb, $chunks[0]['start'], $chunks[0]['len']), true);
dg_check('JSON chunk parses', is_array($json));
dg_check('asset.version is 2.0', ($json['asset']['version'] ?? null) === '2.0');
dg_check('accessors[] and bufferViews[] exist', isset($json['accessors'], $json['bufferViews']));

$alignmentOk = true;
$componentSizes = [5120 => 1, 5121 => 1, 5122 => 2, 5123 => 2, 5125 => 4, 5126 => 4];
foreach ($json['accessors'] as $i => $accessor) {
    $view = $json['bufferViews'][$accessor['bufferView']] ?? null;
    if ($view === null) { $alignmentOk = false; break; }
    $size = $componentSizes[$accessor['componentType']] ?? 1;
    $effective = ($view['byteOffset'] ?? 0) + ($accessor['byteOffset'] ?? 0);
    if ($effective % $size !== 0) { $alignmentOk = false; break; }
}
dg_check('every accessor offset is a multiple of its component size', $alignmentOk);

$viewAlignmentOk = true;
foreach ($json['bufferViews'] as $view) {
    if (($view['byteOffset'] ?? 0) % 4 !== 0) { $viewAlignmentOk = false; break; }
    if (($view['byteLength'] ?? 0) % 4 !== 0) { $viewAlignmentOk = false; break; }
}
dg_check('every bufferView offset and length is 4-byte aligned', $viewAlignmentOk);

$indexView = $json['bufferViews'][$json['accessors'][3]['bufferView']] ?? null;
$indexCount = $json['accessors'][3]['count'] ?? 0;
dg_check('the index accessor count is a multiple of 3 (whole triangles only)', $indexCount % 3 === 0, (string) $indexCount);

$binStart = $chunks[1]['start'];
$indexBytes = substr($glb, $binStart + ($indexView['byteOffset'] ?? 0), ($indexCount * 4));
$lastIndex = $indexCount > 0 ? unpack('V', substr($indexBytes, ($indexCount - 1) * 4, 4))[1] : -1;
$vertexCount = $json['accessors'][0]['count'] ?? 0;
dg_check('the last index is within the vertex count', $lastIndex >= 0 && $lastIndex < $vertexCount, $lastIndex . ' vs ' . $vertexCount);

echo "\n== Two rooms produce more geometry than one ==\n";
$one = (new DollhouseGltfWriter())->write(dg_plan([dg_room('r1', [[0, 0], [4, 0], [4, 3], [0, 3]])]));
$two = (new DollhouseGltfWriter())->write(dg_plan([
    dg_room('r1', [[0, 0], [4, 0], [4, 3], [0, 3]]),
    dg_room('r2', [[4, 0], [7, 0], [7, 3], [4, 3]]),
]));
dg_check('two rooms produce a larger file than one', strlen($two) > strlen($one));

echo "\n== Degenerate input is rejected, not silently produced ==\n";
$threw = false;
try {
    (new DollhouseGltfWriter())->write(dg_plan([]));
} catch (\InvalidArgumentException $e) {
    $threw = true;
}
dg_check('an empty room list is rejected', $threw);

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
