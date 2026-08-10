<?php

declare(strict_types=1);

/**
 * Shared HTTP transport for the net/verify_*.php scripts.
 *
 * This is plumbing, not verification logic — extracting it does NOT
 * conflict with the "net doesn't share assumptions with the code it
 * checks" rule (CLAUDE.md hard constraint #6). Every net script still
 * independently re-derives its own expected values and never imports the
 * adapter/repository/renderer; this file only removes the six copies of
 * curl boilerplate that had drifted into near-duplicates of each other
 * (found by a manual code-quality pass — see PR/commit history).
 */

function net_http_raw(string $method, string $url, ?array $body = null, ?string $accessToken = null): array
{
    return net_http_raw_literal($method, $url, $body !== null ? json_encode($body, JSON_THROW_ON_ERROR) : null, $accessToken);
}

/**
 * Like net_http_raw() but sends $literalBody verbatim, un-encoded. Needed
 * for the one case a real json_encode() can't produce: a payload
 * containing a token like `1e400` that's valid JSON syntax on the wire but
 * overflows to PHP float INF only once decoded server-side.
 */
function net_http_raw_literal(string $method, string $url, ?string $literalBody = null, ?string $accessToken = null): array
{
    $ch = curl_init($url);
    $headers = ['Content-Type: application/json'];
    if ($accessToken !== null) {
        $headers[] = "X-Scan-Access-Token: $accessToken";
    }
    $opts = [
        CURLOPT_CUSTOMREQUEST => $method,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HTTPHEADER => $headers,
    ];
    if ($literalBody !== null) {
        $opts[CURLOPT_POSTFIELDS] = $literalBody;
    }
    curl_setopt_array($ch, $opts);
    $raw = curl_exec($ch);
    if ($raw === false) {
        throw new \RuntimeException('HTTP request failed: ' . curl_error($ch) . " ($method $url)");
    }
    $status = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $contentType = (string) curl_getinfo($ch, CURLINFO_CONTENT_TYPE);
    curl_close($ch);
    return [$status, $contentType, (string) $raw];
}

/** @return array{0: int, 1: array, 2: string} [status, decoded JSON body (or [] if not decodable), raw bytes] */
function net_http_json(string $method, string $url, ?array $body = null, ?string $accessToken = null): array
{
    [$status, , $raw] = net_http_raw($method, $url, $body, $accessToken);
    $decoded = json_decode($raw, true);
    return [$status, is_array($decoded) ? $decoded : [], $raw];
}

/** @return array{0: int, 1: string} [status, response headers as raw text] */
function net_http_headers(string $method, string $url, ?string $accessToken = null): array
{
    $ch = curl_init($url);
    $headers = [];
    if ($accessToken !== null) {
        $headers[] = "X-Scan-Access-Token: $accessToken";
    }
    curl_setopt_array($ch, [
        CURLOPT_CUSTOMREQUEST => $method,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HEADER => true,
        CURLOPT_NOBODY => false,
        CURLOPT_HTTPHEADER => $headers,
    ]);
    $raw = curl_exec($ch);
    if ($raw === false) {
        throw new \RuntimeException('HTTP request failed: ' . curl_error($ch));
    }
    $status = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $headerSize = (int) curl_getinfo($ch, CURLINFO_HEADER_SIZE);
    curl_close($ch);
    return [$status, substr((string) $raw, 0, $headerSize)];
}
