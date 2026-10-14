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


echo "\n== Textured walls when a photo faces them ==\n";

function dg_texture_fixture_jpeg(): string
{
    $img = imagecreatetruecolor(8, 8);
    imagefilledrectangle($img, 0, 0, 8, 8, imagecolorallocate($img, 120, 80, 200));
    ob_start();
    imagejpeg($img, null, 80);
    $jpeg = (string) ob_get_clean();
    imagedestroy($img);
    return $jpeg;
}

function dg_parse_json_chunk(string $glb): array
{
    $totalLen = unpack('V', substr($glb, 8, 4))[1];
    $offset = 12;
    while ($offset + 8 <= $totalLen) {
        $len = unpack('V', substr($glb, $offset, 4))[1];
        $type = unpack('V', substr($glb, $offset + 4, 4))[1];
        if ($type === 0x4E4F534A) {
            return (array) json_decode(substr($glb, $offset + 8, $len), true);
        }
        $offset += 8 + $len;
    }
    return [];
}

$photoJpeg = dg_texture_fixture_jpeg();

$facingPlan = dg_plan([dg_room('r1', [[0.0, 0.0], [4.0, 0.0], [4.0, 3.0], [0.0, 3.0]])]);
$facingPlan['rooms'][0]['heading_deg'] = 0.0;
$facingPlan['photos_360'] = [[
    'photo_id' => 'photo-facing',
    'room_id' => 'r1',
    'url' => 'test://facing.jpg',
    'position_m' => [2.0, 0.5],
    'heading_deg' => 0.0,
    'captured_at' => gmdate('c'),
]];

$loaderCalledWith = [];
$facingLoader = function (string $url) use (&$loaderCalledWith, $photoJpeg): ?string {
    $loaderCalledWith[] = $url;
    return $url === 'test://facing.jpg' ? $photoJpeg : null;
};

$texturedGlb = (new DollhouseGltfWriter())->write($facingPlan, $facingLoader);
dg_check('the photo loader is asked for the room photo url', in_array('test://facing.jpg', $loaderCalledWith, true), json_encode($loaderCalledWith));
$texturedJson = dg_parse_json_chunk($texturedGlb);
dg_check('the textured GLB declares an images array', isset($texturedJson['images']) && count($texturedJson['images']) === 1, json_encode(array_keys($texturedJson)));
dg_check('the textured GLB declares a textures array', isset($texturedJson['textures']) && count($texturedJson['textures']) === 1);
dg_check('the textured GLB declares a samplers array', isset($texturedJson['samplers']) && count($texturedJson['samplers']) === 1);
dg_check('the textured GLB has more than one primitive', isset($texturedJson['meshes'][0]['primitives']) && count($texturedJson['meshes'][0]['primitives']) > 1, (string) (isset($texturedJson['meshes'][0]['primitives']) ? count($texturedJson['meshes'][0]['primitives']) : 0));
$hasUvAccessor = false;
foreach ($texturedJson['accessors'] ?? [] as $acc) {
    if (($acc['type'] ?? '') === 'VEC2') {
        $hasUvAccessor = true;
        break;
    }
}
dg_check('the textured GLB has a VEC2 (TEXCOORD_0) accessor', $hasUvAccessor);
$hasTexCoordPrimitive = false;
$hasColorPrimitive = false;
foreach ($texturedJson['meshes'][0]['primitives'] ?? [] as $prim) {
    $attrs = $prim['attributes'] ?? [];
    if (isset($attrs['TEXCOORD_0'])) {
        $hasTexCoordPrimitive = true;
    }
    if (isset($attrs['COLOR_0'])) {
        $hasColorPrimitive = true;
    }
}
dg_check('one primitive carries TEXCOORD_0 (the textured wall)', $hasTexCoordPrimitive);
dg_check('one primitive still carries COLOR_0 (the flat geometry)', $hasColorPrimitive);

echo "\n== A photo facing away produces no textures ==\n";
$awayPlan = dg_plan([dg_room('r1', [[0.0, 0.0], [4.0, 0.0], [4.0, 3.0], [0.0, 3.0]])]);
$awayPlan['rooms'][0]['heading_deg'] = 0.0;
$awayPlan['photos_360'] = [[
    'photo_id' => 'photo-away',
    'room_id' => 'r1',
    'url' => 'test://away.jpg',
    'position_m' => [2.0, -1.0],
    'heading_deg' => 180.0,
    'captured_at' => gmdate('c'),
]];
$awayGlb = (new DollhouseGltfWriter())->write($awayPlan, fn (string $url): ?string => $photoJpeg);
$awayJson = dg_parse_json_chunk($awayGlb);
dg_check('no images array when the only photo faces away from every wall', !isset($awayJson['images']), json_encode(array_keys($awayJson)));
dg_check('the flat primitive is still emitted', isset($awayJson['meshes'][0]['primitives']) && count($awayJson['meshes'][0]['primitives']) === 1);

echo "\n== A room without heading_deg falls back to flat ==\n";
$noHeadingPlan = dg_plan([dg_room('r1', [[0.0, 0.0], [4.0, 0.0], [4.0, 3.0], [0.0, 3.0]])]);
$noHeadingPlan['photos_360'] = [[
    'photo_id' => 'photo-1',
    'room_id' => 'r1',
    'url' => 'test://some.jpg',
    'position_m' => [2.0, 0.5],
    'heading_deg' => 0.0,
    'captured_at' => gmdate('c'),
]];
$noHeadingGlb = (new DollhouseGltfWriter())->write($noHeadingPlan, fn (string $url): ?string => $photoJpeg);
$noHeadingJson = dg_parse_json_chunk($noHeadingGlb);
dg_check('no images array when the room itself has no heading_deg', !isset($noHeadingJson['images']), json_encode(array_keys($noHeadingJson)));

echo "\n== No loader means the flat path, unchanged ==\n";
$flatOnlyPlan = dg_plan([dg_room('r1', [[0.0, 0.0], [4.0, 0.0], [4.0, 3.0], [0.0, 3.0]])]);
$flatOnlyGlb = (new DollhouseGltfWriter())->write($flatOnlyPlan);
$flatOnlyJson = dg_parse_json_chunk($flatOnlyGlb);
dg_check('the flat path emits exactly one primitive', isset($flatOnlyJson['meshes'][0]['primitives']) && count($flatOnlyJson['meshes'][0]['primitives']) === 1);
dg_check('the flat path has no images array', !isset($flatOnlyJson['images']));
dg_check('the flat path has no samplers array', !isset($flatOnlyJson['samplers']));

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
