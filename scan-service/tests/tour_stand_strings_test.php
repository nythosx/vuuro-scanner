<?php

declare(strict_types=1);

$failures = [];
$checks = 0;

function tss_check(string $label, bool $pass, string $detail = ''): void
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

$path = __DIR__ . '/../public/tour/tour-stand-strings.js';
tss_check('tour-stand-strings.js exists', is_file($path));
$src = (string) file_get_contents($path);

$parts = preg_split('/\bnl\s*:\s*\{/', $src, 2);
tss_check('the file declares an en table followed by an nl table', count($parts) === 2);

if (count($parts) === 2) {
    $keyRegex = '/^      ([a-zA-Z_0-9]+):/m';
    preg_match_all($keyRegex, $parts[0], $enMatch);
    preg_match_all($keyRegex, $parts[1], $nlMatch);

    $en = $enMatch[1];
    $nl = $nlMatch[1];
    sort($en);
    sort($nl);

    $onlyEn = array_values(array_diff($en, $nl));
    $onlyNl = array_values(array_diff($nl, $en));

    tss_check('every English key has a Dutch counterpart', $onlyEn === [], 'missing in nl: ' . implode(', ', $onlyEn));
    tss_check('every Dutch key has an English counterpart', $onlyNl === [], 'missing in en: ' . implode(', ', $onlyNl));
    tss_check('both tables have the same key count', count($en) === count($nl), count($en) . ' vs ' . count($nl));
    tss_check('the tables are not empty', count($en) > 0);

    $enVars = [];
    $nlVars = [];
    preg_match_all('/\{([a-z_]+)\}/', $parts[0], $enVars);
    preg_match_all('/\{([a-z_]+)\}/', $parts[1], $nlVars);
    sort($enVars[1]);
    sort($nlVars[1]);
    tss_check('placeholders match between en and nl', $enVars[1] === $nlVars[1], implode(',', $enVars[1]) . ' vs ' . implode(',', $nlVars[1]));

    tss_check('the t() export is defined', strpos($src, 'window.TourStandStrings') !== false);
}

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
