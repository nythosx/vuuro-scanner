<?php

declare(strict_types=1);

/**
 * Walks a generated PDF's actual object graph (Root -> Pages -> Kids ->
 * each Page's /Contents and /Resources) using the xref table as the only
 * source of object boundaries, so embedded binary (JPEG) streams can never
 * be mistaken for PDF syntax. Returns an empty array when the file is
 * structurally sound; otherwise a list of human-readable problems.
 *
 * @return list<string>
 */
function pdf_validate_object_graph(string $pdf): array
{
    $problems = [];

    if (!str_starts_with($pdf, '%PDF-')) {
        return ['file does not start with %PDF- header'];
    }

    if (!preg_match('/startxref\s+(\d+)\s+%%EOF\s*$/', rtrim($pdf), $sx)) {
        return ['no startxref/%%EOF trailer found'];
    }
    $xrefOffset = (int) $sx[1];
    if (substr($pdf, $xrefOffset, 4) !== 'xref') {
        return ['startxref does not point at the "xref" keyword'];
    }

    if (!preg_match_all('/^(\d{10}) 00000 n \s*$/m', $pdf, $entries)) {
        return ['xref table has no in-use object entries'];
    }
    $offsets = array_map('intval', $entries[1]);
    $count = count($offsets);
    for ($i = 0; $i < $count; $i++) {
        $objNum = $i + 1;
        if (substr($pdf, $offsets[$i], strlen("$objNum 0 obj")) !== "$objNum 0 obj") {
            $problems[] = "xref entry for object $objNum does not point at its \"$objNum 0 obj\" header";
        }
    }
    if ($problems !== []) {
        return $problems;
    }

    if (!preg_match('/trailer\s*<<(.*?)>>/s', $pdf, $trailerMatch)) {
        return ['no trailer dictionary found'];
    }
    if (!preg_match('/\/Root\s+(\d+)\s+0\s+R/', $trailerMatch[1], $rootMatch)) {
        return ['trailer has no /Root reference'];
    }
    $rootNum = (int) $rootMatch[1];

    $objects = [];
    for ($i = 0; $i < $count; $i++) {
        $objNum = $i + 1;
        $start = $offsets[$i];
        $end = $i + 1 < $count ? $offsets[$i + 1] : $xrefOffset;
        $raw = substr($pdf, $start, $end - $start);

        $prefix = "$objNum 0 obj\n";
        $suffix = "\nendobj\n";
        if (!str_starts_with($raw, $prefix) || !str_ends_with($raw, $suffix)) {
            $problems[] = "object $objNum body is not wrapped in \"$objNum 0 obj\" / \"endobj\" as expected";
            continue;
        }
        $body = substr($raw, strlen($prefix), -strlen($suffix));

        $streamMarker = "\nstream\n";
        $streamPos = strpos($body, $streamMarker);
        if ($streamPos === false) {
            $objects[$objNum] = ['dict' => $body, 'stream' => null];
            continue;
        }

        $dict = substr($body, 0, $streamPos);
        if (!preg_match('/\/Length\s+(\d+)/', $dict, $lenMatch)) {
            $problems[] = "object $objNum has a stream but no /Length in its dictionary";
            continue;
        }
        $declaredLength = (int) $lenMatch[1];
        $streamStart = $streamPos + strlen($streamMarker);
        $streamBytes = substr($body, $streamStart, $declaredLength);
        $expectedTail = "\nendstream";
        $actualTail = substr($body, $streamStart + $declaredLength, strlen($expectedTail));
        if (strlen($streamBytes) !== $declaredLength) {
            $problems[] = "object $objNum stream is shorter than its declared /Length $declaredLength";
        } elseif ($actualTail !== $expectedTail) {
            $problems[] = "object $objNum /Length $declaredLength does not land exactly on \"endstream\" (stream is truncated or overrun)";
        }
        $objects[$objNum] = ['dict' => $dict, 'stream' => $streamBytes];
    }
    if ($problems !== []) {
        return $problems;
    }

    $refsIn = static function (string $dictText) use ($count, &$problems, $objects): array {
        preg_match_all('/(\d+)\s+0\s+R/', $dictText, $m);
        $nums = array_map('intval', $m[1]);
        foreach ($nums as $n) {
            if (!isset($objects[$n])) {
                $problems[] = "dictionary references object $n 0 R, which does not exist";
            }
        }
        return $nums;
    };

    if (!isset($objects[$rootNum])) {
        return ["/Root points at object $rootNum, which does not exist"];
    }
    $catalog = $objects[$rootNum]['dict'];
    if (!str_contains($catalog, '/Type /Catalog')) {
        $problems[] = "root object $rootNum is not a /Catalog";
    }
    if (!preg_match('/\/Pages\s+(\d+)\s+0\s+R/', $catalog, $pagesMatch)) {
        return array_merge($problems, ["Catalog (object $rootNum) has no /Pages reference"]);
    }
    $pagesNum = (int) $pagesMatch[1];
    if (!isset($objects[$pagesNum])) {
        return array_merge($problems, ["/Pages points at object $pagesNum, which does not exist"]);
    }

    $pagesDict = $objects[$pagesNum]['dict'];
    if (!preg_match('/\/Kids\s*\[(.*?)\]/s', $pagesDict, $kidsMatch)) {
        return array_merge($problems, ["Pages object $pagesNum has no /Kids array"]);
    }
    $kidNums = $refsIn($kidsMatch[1]);
    if (preg_match('/\/Count\s+(\d+)/', $pagesDict, $countMatch) && (int) $countMatch[1] !== count($kidNums)) {
        $problems[] = "Pages /Count " . $countMatch[1] . ' does not match actual /Kids length ' . count($kidNums);
    }
    if ($kidNums === []) {
        $problems[] = 'Pages object has zero pages';
    }

    $reachable = [$rootNum => true, $pagesNum => true];
    foreach ($kidNums as $pageNum) {
        if (!isset($objects[$pageNum])) {
            continue;
        }
        $reachable[$pageNum] = true;
        $pageDict = $objects[$pageNum]['dict'];
        if (!str_contains($pageDict, '/Type /Page')) {
            $problems[] = "page object $pageNum is not /Type /Page";
        }
        if (!preg_match('/\/MediaBox\s*\[\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*\]/', $pageDict, $mb)) {
            $problems[] = "page object $pageNum has no valid /MediaBox";
        } elseif ((float) $mb[3] <= (float) $mb[1] || (float) $mb[4] <= (float) $mb[2]) {
            $problems[] = "page object $pageNum has a non-positive-area /MediaBox";
        }
        if (!preg_match('/\/Contents\s+(\d+)\s+0\s+R/', $pageDict, $contentsMatch)) {
            $problems[] = "page object $pageNum has no /Contents reference";
        } else {
            $contentsNum = (int) $contentsMatch[1];
            $reachable[$contentsNum] = true;
            if (!isset($objects[$contentsNum]) || $objects[$contentsNum]['stream'] === null) {
                $problems[] = "page $pageNum /Contents $contentsNum is not a real content stream";
            }
        }
        foreach ($refsIn($pageDict) as $refNum) {
            $reachable[$refNum] = true;
        }
    }

    foreach ($objects as $objNum => $obj) {
        if (!isset($reachable[$objNum])) {
            $problems[] = "object $objNum is never referenced from Root (orphaned)";
        }
        if ($obj['stream'] === null && str_contains($obj['dict'], '/Type /XObject') && !str_contains($obj['dict'], '/Subtype /Image')) {
            $problems[] = "object $objNum is an /XObject without an image stream";
        }
    }

    return $problems;
}
