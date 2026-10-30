<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';

use VuuroScan\Export\WallTextureProjection;

$failures = [];
$checks = 0;

function wp_check(string $label, bool $pass, string $detail = ''): void
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

function wp_photo(array $position, float $headingDeg): array
{
    return [
        'photo_id' => 'p',
        'room_id' => 'r',
        'position_m' => $position,
        'heading_deg' => $headingDeg,
    ];
}

echo "== Straight-ahead projection ==\n";
$photo = wp_photo([0.0, 0.0], 0.0);
$uv = WallTextureProjection::projectPoint($photo, 0.0, 0.0, 0.0, 5.0);
wp_check('a point straight ahead projects to the horizontal centre', $uv !== null && abs($uv[0] - 0.5) < 0.01, json_encode($uv));
wp_check('a floor point appears below the horizontal centre', $uv !== null && $uv[1] > 0.5, json_encode($uv));

echo "\n== Points behind or too close ==\n";
wp_check('a point behind the camera returns null', WallTextureProjection::projectPoint($photo, 0.0, 0.0, 0.0, -5.0) === null);
wp_check('a point closer than MIN_DEPTH returns null', WallTextureProjection::projectPoint($photo, 0.0, 0.0, 0.0, 0.05) === null);

echo "\n== Points off the horizontal axis ==\n";
$left = WallTextureProjection::projectPoint($photo, 0.0, -1.0, 0.0, 5.0);
wp_check('a point to the left projects to u < 0.5', $left !== null && $left[0] < 0.5, json_encode($left));
$right = WallTextureProjection::projectPoint($photo, 0.0, 1.0, 0.0, 5.0);
wp_check('a point to the right projects to u > 0.5', $right !== null && $right[0] > 0.5, json_encode($right));
wp_check('a point well outside the frame returns null', WallTextureProjection::projectPoint($photo, 0.0, -50.0, 0.0, 5.0) === null);

echo "\n== Raw projection ignores the frame bounds ==\n";
$raw = WallTextureProjection::projectPointRaw($photo, 0.0, -50.0, 0.0, 5.0);
wp_check('projectPointRaw returns UVs for an out-of-frame point', $raw !== null && $raw[0] < 0.0, json_encode($raw));
wp_check('projectPoint on the same point still returns null', WallTextureProjection::projectPoint($photo, 0.0, -50.0, 0.0, 5.0) === null);
wp_check('projectPointRaw returns null behind the camera', WallTextureProjection::projectPointRaw($photo, 0.0, 0.0, 0.0, -5.0) === null);
wp_check('projectPointRaw returns null closer than MIN_DEPTH', WallTextureProjection::projectPointRaw($photo, 0.0, 0.0, 0.0, 0.05) === null);
wp_check('projectPointRaw returns null without a heading', WallTextureProjection::projectPointRaw(['photo_id' => 'p', 'room_id' => 'r', 'position_m' => [0.0, 0.0]], 0.0, 0.0, 0.0, 5.0) === null);

echo "\n== Room heading rotates the photo's forward direction ==\n";
$photoNorth = wp_photo([0.0, 0.0], 0.0);
$uvSame = WallTextureProjection::projectPoint($photoNorth, 0.0, 0.0, 0.0, 5.0);
wp_check('photo heading equal to room heading looks along +z', $uvSame !== null && abs($uvSame[0] - 0.5) < 0.01, json_encode($uvSame));
$uvRotated = WallTextureProjection::projectPoint($photoNorth, 90.0, 5.0, 0.0, 0.0);
wp_check('photo heading North in a room whose +z is East looks at +x', $uvRotated !== null && abs($uvRotated[0] - 0.5) < 0.01, json_encode($uvRotated));
wp_check('the opposite direction is behind the camera', WallTextureProjection::projectPoint($photoNorth, 90.0, -5.0, 0.0, 0.0) === null);

echo "\n== Compass North in the room's local frame matches DollhouseSceneBuilder ==\n";
foreach ([0.0, 45.0, 90.0, 180.0, 270.0] as $roomHeading) {
    $northPhoto = wp_photo([0.0, 0.0], 0.0);
    $nx = sin(deg2rad($roomHeading));
    $nz = cos(deg2rad($roomHeading));
    $uvNorth = WallTextureProjection::projectPoint(
        $northPhoto,
        $roomHeading,
        $nx * 5.0,
        WallTextureProjection::CAMERA_HEIGHT_M,
        $nz * 5.0
    );
    wp_check(
        "photo facing North at room heading $roomHeading projects the DollhouseSceneBuilder North direction to the centre",
        $uvNorth !== null && abs($uvNorth[0] - 0.5) < 1e-9 && abs($uvNorth[1] - 0.5) < 1e-9,
        json_encode($uvNorth)
    );
}

echo "\n== Missing heading is refused ==\n";
$photoNoHeading = ['photo_id' => 'p', 'room_id' => 'r', 'position_m' => [0.0, 0.0]];
wp_check('a photo without heading_deg returns null', WallTextureProjection::projectPoint($photoNoHeading, 0.0, 0.0, 0.0, 5.0) === null);

echo "\n== Picking a photo for a wall ==\n";
$wallA = [5.0, -2.0];
$wallB = [5.0, 2.0];
$inward = [-1.0, 0.0];
$photos = [
    ['photo_id' => 'a', 'room_id' => 'r', 'position_m' => [0.0, 0.0], 'heading_deg' => 225.0],
    ['photo_id' => 'b', 'room_id' => 'r', 'position_m' => [0.0, 0.0], 'heading_deg' => 270.0],
    ['photo_id' => 'c', 'room_id' => 'r', 'position_m' => [0.0, 0.0], 'heading_deg' => 315.0],
];
$best = WallTextureProjection::pickWallPhoto($wallA, $wallB, $inward, 0.0, 2.5, $photos);
wp_check('the most head-on photo wins', $best !== null && $best['photo_id'] === 'b', json_encode($best['photo_id'] ?? null));

echo "\n== Rejecting photos that cannot see the wall ==\n";
$away = [['photo_id' => 'x', 'room_id' => 'r', 'position_m' => [0.0, 0.0], 'heading_deg' => 90.0]];
wp_check('a photo looking away from the wall returns null', WallTextureProjection::pickWallPhoto($wallA, $wallB, $inward, 0.0, 2.5, $away) === null);
$sideways = [['photo_id' => 'x', 'room_id' => 'r', 'position_m' => [0.0, 0.0], 'heading_deg' => 0.0]];
wp_check('a photo at 90 degrees to the wall returns null', WallTextureProjection::pickWallPhoto($wallA, $wallB, $inward, 0.0, 2.5, $sideways) === null);
$behind = [['photo_id' => 'x', 'room_id' => 'r', 'position_m' => [0.0, 0.0], 'heading_deg' => 0.0]];
wp_check('a wall behind the camera returns null', WallTextureProjection::pickWallPhoto([-5.0, -2.0], [-5.0, 2.0], [1.0, 0.0], 0.0, 2.5, $behind) === null);

echo "\n== Midpoint projection decides visibility, not the endpoints ==\n";
$photoCenter = wp_photo([0.0, 0.0], 270.0);
wp_check('a 4 m wall whose midpoint is in frame passes even though its endpoints are not', WallTextureProjection::pickWallPhoto([5.0, -2.0], [5.0, 2.0], [-1.0, 0.0], 0.0, 2.5, [$photoCenter]) !== null);
wp_check('a 40 m wall with the same midpoint in frame is still rejected as too wide', WallTextureProjection::pickWallPhoto([5.0, -20.0], [5.0, 20.0], [-1.0, 0.0], 0.0, 2.5, [$photoCenter]) === null);
wp_check('a wall fully in frame returns a photo', WallTextureProjection::pickWallPhoto([5.0, -1.0], [5.0, 1.0], [-1.0, 0.0], 0.0, 2.5, [$photoCenter]) !== null);

echo "\n== Photos with camera pose and lens use them ==\n";
$posed = [
    'photo_id' => 'posed',
    'room_id' => 'r',
    'position_m' => [2.0, 0.0],
    'heading_deg' => 0.0,
    'camera_transform' => [-1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, -1.0, 0.0, 2.0, 1.2, 0.0, 1.0],
    'intrinsics' => [1000.0, 1000.0, 960.0, 720.0],
    'image_width' => 1920,
    'image_height' => 1440,
];
$centre = WallTextureProjection::projectPoint($posed, 0.0, 2.0, 1.2, 5.0);
wp_check('a point straight ahead at the real eye height lands in the centre', $centre !== null && abs($centre[0] - 0.5) < 1e-6 && abs($centre[1] - 0.5) < 1e-6, json_encode($centre));
$toRight = WallTextureProjection::projectPoint($posed, 0.0, 1.0, 1.2, 5.0);
wp_check('a point to the right of the camera lands right of centre, scaled by the lens', $toRight !== null && abs($toRight[0] - (1000.0 / 5.0 + 960.0) / 1920.0) < 1e-6, json_encode($toRight));
$above = WallTextureProjection::projectPoint($posed, 0.0, 2.0, 2.2, 5.0);
wp_check('a point above the eye lands in the top half', $above !== null && $above[1] < 0.5, json_encode($above));
wp_check('a posed photo ignores the stored heading', WallTextureProjection::projectPoint([...$posed, 'heading_deg' => 123.0], 0.0, 2.0, 1.2, 5.0) == $centre);
$scaledDown = WallTextureProjection::projectPoint([...$posed, 'image_width' => 960, 'image_height' => 720], 0.0, 2.0, 1.2, 5.0);
wp_check('intrinsics for a larger image are scaled to the stored image', $scaledDown !== null && abs($scaledDown[0] - 0.5) < 1e-6 && abs($scaledDown[1] - 0.5) < 1e-6, json_encode($scaledDown));
$badEye = WallTextureProjection::posedCamera([...$posed, 'camera_transform' => [-1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, -1.0, 0.0, 2.0, 9.0, 0.0, 1.0]]);
wp_check('an impossible eye height falls back to the default', $badEye !== null && $badEye['y'] === WallTextureProjection::CAMERA_HEIGHT_M);
wp_check('a photo without intrinsics is not treated as posed', WallTextureProjection::posedCamera([...$posed, 'intrinsics' => null]) === null);
wp_check('a posed photo facing the wall is picked', WallTextureProjection::pickWallPhoto([0.0, 5.0], [4.0, 5.0], [0.0, -1.0], 0.0, 2.5, [$posed]) !== null);

echo "\n== Older photos still use their tilt ==\n";
$level = WallTextureProjection::projectPoint(wp_photo([0.0, 0.0], 0.0), 0.0, 0.0, WallTextureProjection::CAMERA_HEIGHT_M, 5.0);
$tiltedUp = WallTextureProjection::projectPoint([...wp_photo([0.0, 0.0], 0.0), 'pitch_deg' => 15.0], 0.0, 0.0, WallTextureProjection::CAMERA_HEIGHT_M, 5.0);
wp_check('a level photo puts a point at eye height in the centre', $level !== null && abs($level[1] - 0.5) < 1e-6, json_encode($level));
wp_check('a photo tilted up puts the same point lower in the frame', $tiltedUp !== null && $tiltedUp[1] > 0.55, json_encode($tiltedUp));

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
