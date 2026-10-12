<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';

use VuuroScan\Export\ExportLanguage;
use VuuroScan\Export\FloorPlanImageRenderer;
use VuuroScan\Export\FloorPlanPdfRenderer;
use VuuroScan\Export\FloorPlanSvgRenderer;
use VuuroScan\Export\FurnitureCatalog;
use VuuroScan\Export\UnitFormatter;
use VuuroScan\InspectionTag;
use VuuroScan\RoomType;

$failures = [];
$checks = 0;

function el_check(string $label, bool $pass, string $detail = ''): void
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

function el_translation_keys(string $file): array
{
    $tokens = token_get_all((string) file_get_contents($file));
    $keys = [];
    $count = count($tokens);
    for ($i = 0; $i < $count - 3; $i++) {
        if (!is_array($tokens[$i]) || $tokens[$i][1] !== 'ExportLanguage') {
            continue;
        }
        $j = $i + 1;
        if (($tokens[$j] ?? null) !== null && is_array($tokens[$j]) && $tokens[$j][0] === T_DOUBLE_COLON && is_array($tokens[$j + 1]) && $tokens[$j + 1][1] === 't' && $tokens[$j + 2] === '(') {
            $depth = 0;
            for ($k = $j + 3; $k < $count; $k++) {
                $token = $tokens[$k];
                if ($token === '(' || $token === '[') {
                    $depth++;
                } elseif ($token === ')' || $token === ']') {
                    if ($depth === 0) {
                        break;
                    }
                    $depth--;
                } elseif ($token === ',' && $depth === 0) {
                    break;
                } elseif (is_array($token) && $token[0] === T_CONSTANT_ENCAPSED_STRING && $depth === 0) {
                    $previous = $k - 1;
                    while (is_array($tokens[$previous]) && $tokens[$previous][0] === T_WHITESPACE) {
                        $previous--;
                    }
                    if (!is_array($tokens[$previous]) || !in_array($tokens[$previous][0], [T_IS_IDENTICAL, T_IS_NOT_IDENTICAL, T_IS_EQUAL], true)) {
                        $keys[] = eval('return ' . $token[1] . ';');
                    }
                }
            }
        }
    }
    return $keys;
}

function el_room(string $id, string $label, float $area, ?string $type = null, array $objects = [], array $openings = []): array
{
    return [
        'room_id' => $id, 'label' => $label, 'floor' => 'Begane grond', 'floor_area_m2' => $area, 'perimeter_m' => 14.25,
        'bounding_dimensions_m' => ['width_m' => 4.0, 'length_m' => 3.5], 'confidence' => 'high',
        'outline_m' => [[0, 0], [4, 0], [4, 3.5], [0, 3.5]], 'structure_origin_m' => null, 'openings' => $openings,
        'height_m' => 2.6, 'volume_m3_indicative' => 31.5, 'objects' => $objects,
        'room_type' => $type === null ? null : ['guess' => null, 'confirmed' => $type, 'guess_source' => null],
        'heading_deg' => null, 'coverage' => null,
    ];
}

function el_plan(): array
{
    return [
        'scan_session_id' => 's', 'property_id' => 'Keizersgracht 12', 'unit_id' => '2A', 'organisation_id' => 'org',
        'capture_provider' => 'roomplan', 'captured_at' => '2026-10-06T10:00:00+00:00',
        'measurement_basis' => 'indicative_nen2580_inspired', 'purpose' => 'check_out',
        'rooms' => [
            el_room('r1', 'Room 1', 22.5, 'living_room', [
                ['object_id' => 'o1', 'category' => 'sofa', 'position_m' => [2, 1], 'dimensions_m' => [2, 1, 1], 'yaw_deg' => 0, 'confidence' => 'high'],
                ['object_id' => 'o2', 'category' => 'chair', 'position_m' => [1, 2], 'dimensions_m' => [0.5, 1, 0.5], 'yaw_deg' => 0, 'confidence' => 'high'],
            ], [
                ['category' => 'door', 'position_m' => [0, 1], 'width_m' => 0.9],
                ['category' => 'window', 'position_m' => [4, 1], 'width_m' => 1.2],
                ['category' => 'window', 'position_m' => [4, 2], 'width_m' => 1.2],
            ]),
            el_room('r2', 'Slaapkamer één', 12.25, null),
        ],
        'notes' => [
            ['note_id' => 'n1', 'text' => 'Kras op de vloer', 'room_id' => 'r1', 'created_at' => '2026-10-06T10:00:00+00:00', 'tags' => ['damage']],
            ['note_id' => 'n2', 'text' => 'Sleutels ingeleverd', 'room_id' => null, 'created_at' => '2026-10-06T10:00:00+00:00', 'tags' => []],
        ],
        'photos' => [],
    ];
}

function el_pdf_text(string $pdf): string
{
    preg_match_all('/\/F\d+ [\d.]+ Tf\n[^\n]* Tm\n\((.*?)\) Tj\nET/s', $pdf, $m);
    return mb_convert_encoding(implode("\n", array_map(static fn (string $s) => stripcslashes($s), $m[1])), 'UTF-8', 'Windows-1252');
}

echo "== Every exported English text has a Dutch version ==\n";
$missing = [];
$sources = [...glob(__DIR__ . '/../src/Export/*.php'), __DIR__ . '/../src/RoomType.php', __DIR__ . '/../src/InspectionTag.php'];
$keyCount = 0;
foreach ($sources as $file) {
    foreach (el_translation_keys($file) as $key) {
        $keyCount++;
        if (!array_key_exists($key, ExportLanguage::NL_TEXT)) {
            $missing[] = basename($file) . ': ' . $key;
        }
    }
}
$constants = [
    ...array_values(RoomType::LABELS),
    ...array_values(InspectionTag::LABELS),
    ...array_values(FurnitureCatalog::LABELS),
    ...array_values((new ReflectionClassConstant(FloorPlanPdfRenderer::class, 'PURPOSE_LABELS'))->getValue()),
    (new ReflectionClassConstant(FloorPlanImageRenderer::class, 'FOOTER_TEXT'))->getValue(),
    (new ReflectionClassConstant(FloorPlanSvgRenderer::class, 'FOOTER_TEXT'))->getValue(),
    'high', 'medium', 'low',
];
foreach ($constants as $key) {
    if (!array_key_exists($key, ExportLanguage::NL_TEXT)) {
        $missing[] = 'label: ' . $key;
    }
}
el_check('the scan found the translated texts in the source', $keyCount > 80, (string) $keyCount);
el_check('no English export text is missing in Dutch', $missing === [], implode(' | ', $missing));
$placeholders = [];
foreach (ExportLanguage::NL_TEXT as $en => $nl) {
    preg_match_all('/%[-0-9]*[sd%]/', $en, $a);
    preg_match_all('/%[-0-9]*[sd%]/', $nl, $b);
    if ($a[0] !== $b[0]) {
        $placeholders[] = $en;
    }
}
el_check('every Dutch text keeps the same placeholders in the same order', $placeholders === [], implode(' | ', $placeholders));

echo "\n== Numbers, dates and labels ==\n";
el_check('English stays the default', ExportLanguage::current() === 'en' && UnitFormatter::area(12.5, 'metric') === '12.50 sqm');
ExportLanguage::run('nl', static function (): void {
    el_check('Dutch areas use a decimal comma and m2', UnitFormatter::area(1234.5, 'metric') === "1.234,50 m\u{00B2}", UnitFormatter::area(1234.5, 'metric'));
    el_check('Dutch lengths use a decimal comma', UnitFormatter::length(2.6, 'metric') === '2,60 m');
    el_check('Dutch volumes use m3', UnitFormatter::volume(31.5, 'metric') === "31,50 m\u{00B3}");
    el_check('Dutch dates use Dutch months', ExportLanguage::date('2026-10-06T10:00:00+00:00') === '6 okt 2026');
    el_check('room types are Dutch', RoomType::labelFor('living_room') === 'Woonkamer');
    el_check('inspection tags are Dutch', InspectionTag::labelFor('damage') === 'Schade');
    el_check('openings are counted in Dutch', ExportLanguage::openingCount('window', 2) === '2 ramen' && ExportLanguage::openingCount('door', 1) === '1 deur');
    el_check('known objects are Dutch, unknown stay as captured', ExportLanguage::objectName('sofa') === 'bank' && ExportLanguage::objectName('piano') === 'piano');
});
el_check('the language goes back to English after a Dutch render', ExportLanguage::current() === 'en');
try {
    ExportLanguage::run('nl', static function (): void {
        throw new RuntimeException('render failed');
    });
} catch (RuntimeException) {
}
el_check('the language goes back to English after a failed render', ExportLanguage::current() === 'en');
$unsupported = false;
try {
    ExportLanguage::run('de', static fn () => null);
} catch (InvalidArgumentException) {
    $unsupported = true;
}
el_check('an unsupported language is refused', $unsupported);

echo "\n== PDF ==\n";
$plan = el_plan();
$englishPdf = (new FloorPlanPdfRenderer())->render($plan, 'auto', null, 'metric', null, null, 'default');
$explicitEnglishPdf = ExportLanguage::run('en', static fn () => (new FloorPlanPdfRenderer())->render($plan, 'auto', null, 'metric', null, null, 'default'));
el_check('an explicit English PDF matches the default one', el_pdf_text($englishPdf) === el_pdf_text($explicitEnglishPdf));
$englishText = el_pdf_text($englishPdf);
el_check('the English PDF still reads in English', str_contains($englishText, 'Floor Plan Metrics') && str_contains($englishText, '22.50 sqm') && str_contains($englishText, 'Oct 6, 2026'), $englishText);
$dutchPdf = ExportLanguage::run('nl', static fn () => (new FloorPlanPdfRenderer())->render($plan, 'auto', null, 'metric', null, null, 'default'));
$dutchText = el_pdf_text($dutchPdf);
foreach ([
    'Maten van de plattegrond', 'Doel: Eindinspectie   Gescand: 6 okt 2026', "22,50 m\u{00B2}", 'omtrek', 'betrouwbaarheid: hoog',
    '1 deur, 2 ramen', '1 bank, 1 stoel', 'Woonkamer (Ruimte 1)', 'Notities voor de hele woning', 'labels: Schade',
    'Dit is GEEN gecertificeerde meting', 'Pagina 1 van',
] as $expected) {
    el_check("the Dutch PDF says '$expected'", str_contains($dutchText, $expected), $dutchText);
}
foreach (['Floor Plan Metrics', 'perimeter', 'confidence', 'Whole-unit notes', 'Page 1 of', ' sqm', 'Total indicative area', 'room(s)', 'Room 1'] as $english) {
    el_check("the Dutch PDF no longer says '$english'", !str_contains($dutchText, $english));
}
el_check('user text is never translated', str_contains($dutchText, 'Slaapkamer één') && str_contains($dutchText, 'Keizersgracht 12'));

echo "\n== PNG and SVG ==\n";
$englishPng = (new FloorPlanImageRenderer())->render($plan);
$dutchPng = ExportLanguage::run('nl', static fn () => (new FloorPlanImageRenderer())->render($plan));
el_check('the Dutch PNG is drawn with different text', $englishPng !== $dutchPng);
el_check('the English PNG is the same as before', $englishPng === ExportLanguage::run('en', static fn () => (new FloorPlanImageRenderer())->render($plan)));
$dutchSvg = ExportLanguage::run('nl', static fn () => (new FloorPlanSvgRenderer())->render($plan));
el_check('the Dutch SVG has the Dutch footer', str_contains($dutchSvg, 'niet gecertificeerd'));
el_check('the Dutch SVG has Dutch areas', str_contains($dutchSvg, "22,50 m\u{00B2}"));
$longNote = $plan;
$longNote['notes'][] = ['note_id' => 'n3', 'text' => str_repeat('é', 150), 'room_id' => 'r2', 'created_at' => '2026-10-06T10:00:00+00:00', 'tags' => []];
$longSvg = ExportLanguage::run('nl', static fn () => (new FloorPlanSvgRenderer())->render($longNote));
el_check('a long accented note keeps the SVG valid UTF-8 and XML', mb_check_encoding($longSvg, 'UTF-8') && @simplexml_load_string($longSvg) !== false);

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
