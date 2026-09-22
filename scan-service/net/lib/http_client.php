<?php

declare(strict_types=1);



function net_http_raw(string $method, string $url, ?array $body = null, ?string $accessToken = null): array
{
    return net_http_raw_literal($method, $url, $body !== null ? json_encode($body, JSON_THROW_ON_ERROR) : null, $accessToken);
}


const NET_HTTP_CONNECT_RETRY_ATTEMPTS = 6;
const NET_HTTP_CONNECT_TIMEOUT_MS = 3000;
const NET_HTTP_CONNECT_RETRY_DELAY_US = 500_000;
const NET_HTTP_RETRYABLE_CURL_ERRNOS = [
    CURLE_COULDNT_CONNECT,
    CURLE_OPERATION_TIMEDOUT,
];

function net_http_exec_with_retry(\CurlHandle $ch, string $method, string $url): string
{
    curl_setopt($ch, CURLOPT_CONNECTTIMEOUT_MS, NET_HTTP_CONNECT_TIMEOUT_MS);
    for ($attempt = 1; $attempt <= NET_HTTP_CONNECT_RETRY_ATTEMPTS; $attempt++) {
        $raw = curl_exec($ch);
        if ($raw !== false) {
            return $raw;
        }
        $errno = curl_errno($ch);
        if ($attempt === NET_HTTP_CONNECT_RETRY_ATTEMPTS || !in_array($errno, NET_HTTP_RETRYABLE_CURL_ERRNOS, true)) {
            throw new \RuntimeException('HTTP request failed: ' . curl_error($ch) . " ($method $url)");
        }
        usleep(NET_HTTP_CONNECT_RETRY_DELAY_US);
    }
    throw new \RuntimeException("HTTP request failed: unreachable retry loop exit ($method $url)");
}


function net_http_raw_literal(string $method, string $url, ?string $literalBody = null, ?string $accessToken = null, array $extraHeaders = []): array
{
    $ch = curl_init($url);
    $headers = ['Content-Type: application/json'];
    if ($accessToken !== null) {
        $headers[] = "X-Scan-Access-Token: $accessToken";
    }
    foreach ($extraHeaders as $name => $value) {
        $headers[] = "$name: $value";
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
    $raw = net_http_exec_with_retry($ch, $method, $url);
    $status = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $contentType = (string) curl_getinfo($ch, CURLINFO_CONTENT_TYPE);
    curl_close($ch);
    return [$status, $contentType, $raw];
}


function net_http_json_ex(string $method, string $url, ?array $body, ?string $accessToken, array $extraHeaders): array
{
    $literalBody = $body !== null ? json_encode($body, JSON_THROW_ON_ERROR) : null;
    [$status, , $raw] = net_http_raw_literal($method, $url, $literalBody, $accessToken, $extraHeaders);
    $decoded = json_decode($raw, true);
    return [$status, is_array($decoded) ? $decoded : [], $raw];
}


function net_http_json(string $method, string $url, ?array $body = null, ?string $accessToken = null): array
{
    [$status, , $raw] = net_http_raw($method, $url, $body, $accessToken);
    $decoded = json_decode($raw, true);
    return [$status, is_array($decoded) ? $decoded : [], $raw];
}


function net_http_multipart_upload(string $url, string $filePath, string $mimeType, ?string $accessToken = null): array
{
    $ch = curl_init($url);
    $headers = [];
    if ($accessToken !== null) {
        $headers[] = "X-Scan-Access-Token: $accessToken";
    }
    curl_setopt_array($ch, [
        CURLOPT_POST => true,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HTTPHEADER => $headers,
        CURLOPT_POSTFIELDS => ['photo' => new \CURLFile($filePath, $mimeType, basename($filePath))],
    ]);
    $raw = net_http_exec_with_retry($ch, 'POST', $url);
    $status = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    $decoded = json_decode($raw, true);
    return [$status, is_array($decoded) ? $decoded : [], $raw];
}


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
    $raw = net_http_exec_with_retry($ch, $method, $url);
    $status = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $headerSize = (int) curl_getinfo($ch, CURLINFO_HEADER_SIZE);
    curl_close($ch);
    return [$status, substr($raw, 0, $headerSize)];
}
