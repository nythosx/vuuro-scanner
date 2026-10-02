<?php

declare(strict_types=1);

require_once __DIR__ . '/../tests/lib/render_scenarios.php';

use VuuroScan\Export\FloorPlanImageRenderer;
use VuuroScan\Export\FloorPlanSvgRenderer;

if (($argv[1] ?? '') === '') {
    fwrite(STDERR, "Usage: php tools/render_review.php <scratch-dir>\n");
    exit(2);
}

$outDir = rtrim((string) $argv[1], '/\\');
if (!is_dir($outDir) && !mkdir($outDir, 0700, true)) {
    fwrite(STDERR, "Could not create output directory: $outDir\n");
    exit(2);
}

$imageRenderer = new FloorPlanImageRenderer();
$svgRenderer = new FloorPlanSvgRenderer();
$indexRows = [];

foreach (render_scenarios() as $key => $scenario) {
    $plan = $scenario['plan'];
    $layout = $scenario['layout'] ?? 'auto';
    $roomId = $scenario['room_id'] ?? null;

    try {
        $png = $imageRenderer->render($plan, $layout, $roomId, \VuuroScan\Export\UnitFormatter::METRIC, null);
        $svg = $svgRenderer->render($plan, $layout, $roomId, \VuuroScan\Export\UnitFormatter::METRIC, null);
    } catch (\Throwable $e) {
        fwrite(STDERR, "render $key failed: " . get_class($e) . ': ' . $e->getMessage() . "\n");
        continue;
    }

    $pngPath = $outDir . '/' . $key . '.png';
    $svgPath = $outDir . '/' . $key . '.svg';
    file_put_contents($pngPath, $png);
    file_put_contents($svgPath, $svg);
    file_put_contents($outDir . '/' . $key . '.pdf', (new \VuuroScan\Export\FloorPlanPdfRenderer())->render($plan, $layout, $roomId, \VuuroScan\Export\UnitFormatter::METRIC, null));

    $indexRows[] = '<section><h2>' . htmlspecialchars($key, ENT_QUOTES) . '</h2>'
        . '<img src="' . htmlspecialchars(basename($pngPath), ENT_QUOTES) . '" alt="' . htmlspecialchars($key, ENT_QUOTES) . '"/>'
        . '</section>';
    echo "rendered $key -> " . basename($pngPath) . ' (' . strlen($png) . " bytes)\n";
}

$index = '<!doctype html><html><head><meta charset="utf-8"><title>Render review</title>'
    . '<style>body{font-family:system-ui;background:#111;color:#eee;margin:24px}img{max-width:100%;border:1px solid #444;margin:8px 0}section{margin-bottom:32px}</style>'
    . '</head><body><h1>Render review</h1>' . implode("\n", $indexRows) . '</body></html>';
file_put_contents($outDir . '/index.html', $index);
echo "index -> " . $outDir . "/index.html\n";
