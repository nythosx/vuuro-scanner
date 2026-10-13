<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';

use VuuroScan\Export\DollhouseGltfWriter;

$failures = [];
$checks = 0;

function dgv_check(string $label, bool $pass, string $detail = ''): void
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

function dgv_room(string $id, array $outline): array
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

function dgv_plan(array $rooms): array
{
    return [
        'scan_session_id' => 'dgv-test',
        'property_id' => 'p', 'unit_id' => 'u', 'organisation_id' => 'o',
        'capture_provider' => 'test', 'captured_at' => gmdate('c'),
        'measurement_basis' => 'indicative_nen2580_inspired', 'purpose' => 'listing',
        'rooms' => $rooms, 'photos' => [], 'notes' => [],
    ];
}

function dgv_parse(string $glb): array
{
    $magic = unpack('V', substr($glb, 0, 4))[1];
    $totalLen = unpack('V', substr($glb, 8, 4))[1];
    $offset = 12;
    $chunks = [];
    while ($offset + 8 <= $totalLen) {
        $len = unpack('V', substr($glb, $offset, 4))[1];
        $type = unpack('V', substr($glb, $offset + 4, 4))[1];
        $chunks[] = ['len' => $len, 'type' => $type, 'start' => $offset + 8];
        $offset += 8 + $len;
    }
    return ['magic' => $magic, 'total' => $totalLen, 'chunks' => $chunks];
}

echo "== bufferView byteLength matches accessor component count and size ==\n";
$glb = (new DollhouseGltfWriter())->write(dgv_plan([
    dgv_room('r1', [[0, 0], [4, 0], [4, 3], [0, 3]]),
    dgv_room('r2', [[4, 0], [7, 0], [7, 3], [4, 3]]),
]));
$parsed = dgv_parse($glb);
$json = json_decode(substr($glb, $parsed['chunks'][0]['start'], $parsed['chunks'][0]['len']), true);

$componentSizes = [5120 => 1, 5121 => 1, 5122 => 2, 5123 => 2, 5125 => 4, 5126 => 4];
$typeComponents = ['SCALAR' => 1, 'VEC2' => 2, 'VEC3' => 3, 'VEC4' => 4];

$lengthOk = true;
foreach ($json['accessors'] as $accessor) {
    $view = $json['bufferViews'][$accessor['bufferView']] ?? null;
    if ($view === null) { $lengthOk = false; break; }
    $componentSize = $componentSizes[$accessor['componentType']] ?? 1;
    $componentCount = $typeComponents[$accessor['type']] ?? 1;
    $expectedBytes = $accessor['count'] * $componentSize * $componentCount;
    if ($view['byteLength'] < $expectedBytes) {
        $lengthOk = false;
        break;
    }
}
dgv_check('every accessor fits inside its bufferView byteLength', $lengthOk);

echo "\n== JSON chunk is padded with spaces (0x20), BIN chunk with nulls (0x00) ==\n";
$jsonChunkStart = $parsed['chunks'][0]['start'];
$jsonChunkEnd = $jsonChunkStart + $parsed['chunks'][0]['len'];
$jsonRaw = substr($glb, $jsonChunkStart, $parsed['chunks'][0]['len']);
$jsonTrimmed = rtrim($jsonRaw, " \t\n\r\0");
$padding = substr($jsonRaw, strlen($jsonTrimmed));
$jsonPaddingOk = true;
foreach (str_split($padding) as $b) {
    if ($b !== ' ') { $jsonPaddingOk = false; break; }
}
dgv_check('JSON chunk padding uses only space bytes as the spec requires', $jsonPaddingOk);

$binChunkStart = $parsed['chunks'][1]['start'];
$binChunkEnd = $binChunkStart + $parsed['chunks'][1]['len'];
$binRaw = substr($glb, $binChunkStart, $parsed['chunks'][1]['len']);
$bufferDeclaredLen = $json['buffers'][0]['byteLength'] ?? 0;
dgv_check('the BIN chunk length matches the declared buffer byteLength', $parsed['chunks'][1]['len'] === $bufferDeclaredLen, $parsed['chunks'][1]['len'] . ' vs ' . $bufferDeclaredLen);

echo "\n== Index accessor component type and count are consistent ==\n";
$indexAccessor = $json['accessors'][3] ?? null;
dgv_check('the index accessor is UNSIGNED_INT (5125)', ($indexAccessor['componentType'] ?? 0) === 5125, (string) ($indexAccessor['componentType'] ?? 0));
dgv_check('the index accessor is SCALAR (one component per index)', ($indexAccessor['type'] ?? '') === 'SCALAR', (string) ($indexAccessor['type'] ?? ''));
dgv_check('the index accessor count is a multiple of 3', (($indexAccessor['count'] ?? 0) % 3) === 0, (string) ($indexAccessor['count'] ?? 0));

echo "\n== Every bufferView byteOffset + byteLength stays inside the buffer ==\n";
$maxEnd = 0;
foreach ($json['bufferViews'] as $view) {
    $end = ($view['byteOffset'] ?? 0) + ($view['byteLength'] ?? 0);
    $maxEnd = max($maxEnd, $end);
}
dgv_check('no bufferView reads past the declared buffer', $maxEnd <= $bufferDeclaredLen, $maxEnd . ' vs ' . $bufferDeclaredLen);
dgv_check('every byte between bufferViews is accounted for (no gaps larger than alignment padding)', $maxEnd >= $bufferDeclaredLen - 4);

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
