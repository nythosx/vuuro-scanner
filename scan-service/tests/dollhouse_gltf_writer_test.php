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

echo "\n== Web dollhouse draws a wall shared by two rooms once, like the app ==\n";
function dg_positions(string $glb): array
{
    $json = dg_parse_json_chunk($glb);
    $totalLen = unpack('V', substr($glb, 8, 4))[1];
    $offset = 12;
    $bin = '';
    while ($offset + 8 <= $totalLen) {
        $len = unpack('V', substr($glb, $offset, 4))[1];
        $type = unpack('V', substr($glb, $offset + 4, 4))[1];
        if ($type === 0x004E4942) {
            $bin = substr($glb, $offset + 8, $len);
        }
        $offset += 8 + $len;
    }
    $points = [];
    foreach ($json['meshes'] ?? [] as $mesh) {
        foreach ($mesh['primitives'] ?? [] as $primitive) {
            $accessor = $json['accessors'][$primitive['attributes']['POSITION']];
            $view = $json['bufferViews'][$accessor['bufferView']];
            $start = ($view['byteOffset'] ?? 0) + ($accessor['byteOffset'] ?? 0);
            $floats = unpack('g*', substr($bin, $start, $accessor['count'] * 12));
            $floats = array_values($floats);
            for ($k = 0; $k + 2 < count($floats); $k += 3) {
                $points[] = [$floats[$k], $floats[$k + 1], $floats[$k + 2]];
            }
        }
    }
    return $points;
}

function dg_band(array $points, float $height, float $xMin, float $xMax): ?array
{
    $xs = [];
    foreach ($points as [$x, $y, $z]) {
        if (abs($y - $height) < 1e-3 && $x >= $xMin && $x <= $xMax) {
            $xs[] = $x;
        }
    }
    return $xs === [] ? null : [min($xs), max($xs)];
}

$left = dg_room('left', [[0.0, 0.0], [4.0, 0.0], [4.0, 3.0], [0.0, 3.0]]);
$left['open_edges'] = [0, 2];
$right = dg_room('right', [[0.0, 0.0], [3.0, 0.0], [3.0, 3.0], [0.0, 3.0]]);
$right['structure_origin_m'] = [4.2, 0.0];
$right['open_edges'] = [0, 2];
$fusedPoints = dg_positions((new DollhouseGltfWriter())->write(dg_plan([$left, $right]), fn (string $url): ?string => null));
$seam = dg_band($fusedPoints, 2.6, 3.0, 5.5);
$outer = dg_band($fusedPoints, 2.6, -1.0, 1.0);
dg_check('the shared wall uses the thin interior thickness on the room side', $seam !== null && abs($seam[0] - 3.97) < 0.02, 'seam band ' . json_encode($seam));
dg_check('the shared wall fills the gap between the rooms once instead of two thick walls', $seam !== null && ($seam[1] - $seam[0]) < 0.38, 'seam band ' . json_encode($seam));
dg_check('an outside wall keeps the exterior thickness', $outer !== null && abs(($outer[1] - $outer[0]) - 0.15) < 0.02, 'outer band ' . json_encode($outer));

$openRoom = dg_room('open', [[0.0, 0.0], [4.0, 0.0], [4.0, 3.0], [0.0, 3.0]]);
$openRoom['open_edges'] = [0, 1, 2];
$openPoints = dg_positions((new DollhouseGltfWriter())->write(dg_plan([$openRoom]), fn (string $url): ?string => null));
dg_check('an open edge gets no wall', dg_band($openPoints, 2.6, 3.5, 4.5) === null, json_encode(dg_band($openPoints, 2.6, 3.5, 4.5)));
dg_check('the other walls are still drawn', dg_band($openPoints, 2.6, -1.0, 1.0) !== null);

$upstairs = $right;
$upstairs['room_id'] = 'upstairs';
$upstairs['floor'] = 'First';
$floorsPoints = dg_positions((new DollhouseGltfWriter())->write(dg_plan([$left, $upstairs]), fn (string $url): ?string => null));
$crossFloor = dg_band($floorsPoints, 2.6, 3.0, 5.5);
dg_check('rooms on different floors are not joined into one interior wall', $crossFloor !== null && abs($crossFloor[0] - 3.925) < 0.02, 'band ' . json_encode($crossFloor));

echo "\n== Web dollhouse stacks floors and tells the viewer where each room went ==\n";
$groundRoom = dg_room('ground', [[0.0, 0.0], [4.0, 0.0], [4.0, 3.0], [0.0, 3.0]]);
$firstRoom = dg_room('first', [[0.0, 0.0], [4.0, 0.0], [4.0, 3.0], [0.0, 3.0]]);
$firstRoom['floor'] = 'First';
$firstRoom['structure_origin_m'] = [10.0, 5.0];
$stackedGlb = (new DollhouseGltfWriter())->write(dg_plan([$firstRoom, $groundRoom]), fn (string $url): ?string => null);
$stackedPoints = dg_positions($stackedGlb);
$minY = min(array_column($stackedPoints, 1));
$maxY = max(array_column($stackedPoints, 1));
dg_check('the ground floor stays on the ground', abs($minY) < 1e-3, "min y $minY");
dg_check('the first floor sits above the ground floor', $maxY > 2.6 + 0.6 + 2.6 - 0.01, "max y $maxY");
$stackedJson = dg_parse_json_chunk($stackedGlb);
$poses = $stackedJson['scenes'][0]['extras']['room_poses'] ?? [];
$byId = array_column($poses, null, 'room_id');
dg_check('the GLB lists a pose for every room', isset($byId['ground'], $byId['first']), json_encode(array_keys($byId)));
dg_check('the first floor pose is lifted above the ground floor', ($byId['first']['base_y'] ?? 0) > 3.0 && ($byId['ground']['base_y'] ?? 1) == 0.0, json_encode($poses));
dg_check('stacked floors share one footprint', abs(($byId['first']['origin_x'] ?? 99) - ($byId['ground']['origin_x'] ?? -99)) < 1e-6, json_encode($poses));

$singleFloorJson = dg_parse_json_chunk((new DollhouseGltfWriter())->write(dg_plan([$groundRoom]), fn (string $url): ?string => null));
$singlePose = $singleFloorJson['scenes'][0]['extras']['room_poses'][0] ?? [];
dg_check('a one-floor plan keeps its rooms where they were captured', ($singlePose['origin_x'] ?? null) == 0.0 && ($singlePose['base_y'] ?? null) == 0.0, json_encode($singlePose));

echo "\n== Web dollhouse shows doors and windows like the app ==\n";
$doorRoom = dg_room('door-room', [[0.0, 0.0], [4.0, 0.0], [4.0, 3.0], [0.0, 3.0]]);
$doorRoom['openings'] = [['opening_id' => 'd1', 'category' => 'door', 'position_m' => [2.0, 0.0], 'width_m' => 0.9, 'confidence' => 'high']];
$doorPoints = dg_positions((new DollhouseGltfWriter())->write(dg_plan([$doorRoom]), fn (string $url): ?string => null));
$aboveDoor = array_filter($doorPoints, static fn ($p) => abs($p[0] - 1.55) < 0.005 && abs($p[1] - 2.05) < 0.005 && abs(abs($p[2]) - 0.075) < 0.005);
dg_check('there is wall above the door', $aboveDoor !== []);
$postInner = array_filter($doorPoints, static fn ($p) => abs($p[0] - (1.55 + 0.04)) < 0.005 && $p[1] < 2.0);
dg_check('the door has a thin frame post on its side', $postInner !== []);
$insideDoor = array_filter($doorPoints, static fn ($p) => $p[0] > 1.65 && $p[0] < 2.35 && $p[1] > 0.01 && $p[1] < 1.9 && abs($p[2]) < 0.3);
dg_check('the doorway itself stays open', $insideDoor === [], count($insideDoor) . ' vertices inside the doorway');

$windowRoom = dg_room('window-room', [[0.0, 0.0], [4.0, 0.0], [4.0, 3.0], [0.0, 3.0]]);
$windowRoom['openings'] = [['opening_id' => 'w1', 'category' => 'window', 'position_m' => [2.0, 0.0], 'width_m' => 1.2, 'confidence' => 'high']];
$windowPoints = dg_positions((new DollhouseGltfWriter())->write(dg_plan([$windowRoom]), fn (string $url): ?string => null));
$belowWindow = array_filter($windowPoints, static fn ($p) => abs($p[0] - 1.4) < 0.005 && abs($p[1] - 0.9) < 0.005 && abs(abs($p[2]) - 0.075) < 0.005);
$aboveWindow = array_filter($windowPoints, static fn ($p) => abs($p[0] - 1.4) < 0.005 && abs($p[1] - 2.1) < 0.005 && abs(abs($p[2]) - 0.075) < 0.005);
dg_check('there is wall below the window', $belowWindow !== []);
dg_check('there is wall above the window', $aboveWindow !== []);

$texturedDoorPlan = dg_plan([$doorRoom]);
$texturedDoorPlan['rooms'][0]['heading_deg'] = 0.0;
$texturedDoorPlan['photos_360'] = [[
    'photo_id' => 'photo-door', 'room_id' => 'door-room', 'url' => 'test://door.jpg',
    'position_m' => [2.0, 2.5], 'heading_deg' => 180.0, 'captured_at' => gmdate('c'),
]];
$texturedDoorJson = dg_parse_json_chunk((new DollhouseGltfWriter())->write($texturedDoorPlan, fn (string $url): ?string => $photoJpeg));
$texturedPrimitives = array_filter($texturedDoorJson['meshes'][0]['primitives'] ?? [], static fn ($p) => isset($p['attributes']['TEXCOORD_0']));
dg_check('wall pieces around a door that share one photo are one textured primitive', count($texturedPrimitives) === 1, count($texturedPrimitives) . ' textured primitives');
dg_check('the shared photo is embedded once', count($texturedDoorJson['images'] ?? []) === 1);

function dg_accessor(string $glb, array $json, int $index): array
{
    $totalLen = unpack('V', substr($glb, 8, 4))[1];
    $offset = 12;
    $bin = '';
    while ($offset + 8 <= $totalLen) {
        $len = unpack('V', substr($glb, $offset, 4))[1];
        if (unpack('V', substr($glb, $offset + 4, 4))[1] === 0x004E4942) {
            $bin = substr($glb, $offset + 8, $len);
        }
        $offset += 8 + $len;
    }
    $accessor = $json['accessors'][$index];
    $view = $json['bufferViews'][$accessor['bufferView']];
    $start = ($view['byteOffset'] ?? 0) + ($accessor['byteOffset'] ?? 0);
    $width = ['SCALAR' => 1, 'VEC2' => 2, 'VEC3' => 3, 'VEC4' => 4][$accessor['type']];
    $format = $accessor['componentType'] === 5125 ? 'V*' : 'g*';
    $values = array_values(unpack($format, substr($bin, $start, $accessor['count'] * $width * 4)));
    return $width === 1 ? $values : array_chunk($values, $width);
}

function dg_backfacing_triangles(string $glb): int
{
    $json = dg_parse_json_chunk($glb);
    $wrong = 0;
    foreach ($json['meshes'] ?? [] as $mesh) {
        foreach ($mesh['primitives'] ?? [] as $primitive) {
            $positions = dg_accessor($glb, $json, $primitive['attributes']['POSITION']);
            $normals = dg_accessor($glb, $json, $primitive['attributes']['NORMAL']);
            $indices = dg_accessor($glb, $json, $primitive['indices']);
            for ($t = 0; $t + 2 < count($indices); $t += 3) {
                [$a, $b, $c] = [$positions[$indices[$t]], $positions[$indices[$t + 1]], $positions[$indices[$t + 2]]];
                $e1 = [$b[0] - $a[0], $b[1] - $a[1], $b[2] - $a[2]];
                $e2 = [$c[0] - $a[0], $c[1] - $a[1], $c[2] - $a[2]];
                $cross = [$e1[1] * $e2[2] - $e1[2] * $e2[1], $e1[2] * $e2[0] - $e1[0] * $e2[2], $e1[0] * $e2[1] - $e1[1] * $e2[0]];
                $n = $normals[$indices[$t]];
                if ($cross[0] * $n[0] + $cross[1] * $n[1] + $cross[2] * $n[2] < 0) {
                    $wrong++;
                }
            }
        }
    }
    return $wrong;
}

function dg_overlap_vertices(string $glb): int
{
    $json = dg_parse_json_chunk($glb);
    $red = 0;
    foreach ($json['meshes'][0]['primitives'] ?? [] as $primitive) {
        if (!isset($primitive['attributes']['COLOR_0'])) {
            continue;
        }
        foreach (dg_accessor($glb, $json, $primitive['attributes']['COLOR_0']) as $color) {
            if (abs($color[0] - 0.84) < 0.01 && abs($color[1] - 0.27) < 0.01) {
                $red++;
            }
        }
    }
    return $red;
}

echo "\n== Every triangle faces the way its normal points ==\n";
$windingPlan = dg_plan([
    dg_room('r1', [[0, 0], [4, 0], [4, 3], [0, 3]]),
    dg_room('r2', [[4, 0], [4, 3], [7, 3], [7, 0]]),
]);
$windingPlan['rooms'][0]['openings'] = [[
    'opening_id' => 'd1', 'category' => 'door', 'width_m' => 0.9, 'height_m' => 2.0,
    'position_m' => [2.0, 0.0], 'confidence' => 'high',
]];
$w = dg_backfacing_triangles((new DollhouseGltfWriter())->write($windingPlan));
dg_check('flat GLB has no back-facing triangles', $w === 0, "$w back-facing");
$windingPlan['rooms'][0]['heading_deg'] = 0.0;
$windingPlan['photos_360'] = $facingPlan['photos_360'];
$w = dg_backfacing_triangles((new DollhouseGltfWriter())->write($windingPlan, fn (string $url): ?string => $photoJpeg));
dg_check('textured GLB has no back-facing triangles', $w === 0, "$w back-facing");

echo "\n== Rooms stacked on two floors are not an overlap ==\n";
$upper = dg_room('u1', [[0, 0], [4, 0], [4, 3], [0, 3]]);
$upper['floor'] = '1st floor';
$stackedPlan = dg_plan([dg_room('g1', [[0, 0], [4, 0], [4, 3], [0, 3]]), $upper]);
$stackedPlan['photos_360'] = [];
$red = dg_overlap_vertices((new DollhouseGltfWriter())->write($stackedPlan, fn (string $url): ?string => null));
dg_check('no overlap colour on rooms stacked on two floors', $red === 0, "$red red vertices");
$sameFloor = dg_plan([dg_room('a1', [[0, 0], [4, 0], [4, 3], [0, 3]]), dg_room('a2', [[1, 0], [5, 0], [5, 3], [1, 3]])]);
$sameFloor['photos_360'] = [];
$red = dg_overlap_vertices((new DollhouseGltfWriter())->write($sameFloor, fn (string $url): ?string => null));
dg_check('rooms that overlap on the same floor are still flagged', $red > 0, 'no red vertices');

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
