<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class LidarModelKtx2
{
    public const EXTENSION = 'KHR_texture_basisu';
    public const IMAGE_TIMEOUT_S = 180;

    public static function encoder(): ?string
    {
        $configured = getenv('SCAN_SERVICE_TOKTX');
        $candidates = is_string($configured) && $configured !== '' ? [$configured] : ['/usr/bin/toktx', '/usr/local/bin/toktx'];
        foreach ($candidates as $candidate) {
            if (is_file($candidate) && is_executable($candidate)) {
                return $candidate;
            }
        }
        return null;
    }

    public static function rewrite(string $glb, callable $encode): array
    {
        $parsed = self::parse($glb);
        if (isset($parsed['error'])) {
            return ['ok' => false, 'message' => $parsed['error']];
        }
        $gltf = $parsed['json'];
        $bin = $parsed['bin'];
        $images = is_array($gltf['images'] ?? null) ? $gltf['images'] : [];
        $views = is_array($gltf['bufferViews'] ?? null) ? $gltf['bufferViews'] : [];
        if ($images === []) {
            return ['ok' => false, 'message' => 'the model has no photos to compress'];
        }
        $replaced = [];
        foreach ($images as $index => $image) {
            $view = $image['bufferView'] ?? null;
            $mime = $image['mimeType'] ?? '';
            if (!is_int($view) || !isset($views[$view]) || !in_array($mime, ['image/jpeg', 'image/png'], true)) {
                return ['ok' => false, 'message' => "photo $index is not a JPEG or PNG inside the model"];
            }
            $offset = (int) ($views[$view]['byteOffset'] ?? 0);
            $length = (int) ($views[$view]['byteLength'] ?? 0);
            if ($length <= 0 || $offset < 0 || $offset + $length > strlen($bin)) {
                return ['ok' => false, 'message' => "photo $index runs past the model data"];
            }
            $encoded = $encode(substr($bin, $offset, $length), $mime, $index);
            if (!is_array($encoded) || !($encoded['ok'] ?? false) || !is_string($encoded['data'] ?? null) || $encoded['data'] === '') {
                $reason = is_array($encoded) && is_string($encoded['message'] ?? null) ? $encoded['message'] : 'the encoder gave nothing back';
                return ['ok' => false, 'message' => "photo $index could not be compressed: $reason"];
            }
            $replaced[$view] = $encoded['data'];
            $images[$index] = ['bufferView' => $view, 'mimeType' => 'image/ktx2'];
        }
        $newBin = '';
        foreach ($views as $index => $view) {
            $bytes = $replaced[$index] ?? substr($bin, (int) ($view['byteOffset'] ?? 0), (int) ($view['byteLength'] ?? 0));
            $newBin .= str_repeat("\0", (4 - strlen($newBin) % 4) % 4);
            $views[$index]['byteOffset'] = strlen($newBin);
            $views[$index]['byteLength'] = strlen($bytes);
            $views[$index]['buffer'] = 0;
            $newBin .= $bytes;
        }
        $gltf['images'] = $images;
        $gltf['bufferViews'] = $views;
        $gltf['buffers'] = [['byteLength' => strlen($newBin)]];
        $textures = is_array($gltf['textures'] ?? null) ? $gltf['textures'] : [];
        foreach ($textures as $index => $texture) {
            if (!is_int($texture['source'] ?? null)) {
                continue;
            }
            $extensions = is_array($texture['extensions'] ?? null) ? $texture['extensions'] : [];
            $extensions[self::EXTENSION] = ['source' => $texture['source']];
            $texture['extensions'] = $extensions;
            unset($texture['source']);
            $textures[$index] = $texture;
        }
        $gltf['textures'] = $textures;
        foreach (['extensionsUsed', 'extensionsRequired'] as $key) {
            $list = is_array($gltf[$key] ?? null) ? $gltf[$key] : [];
            if (!in_array(self::EXTENSION, $list, true)) {
                $list[] = self::EXTENSION;
            }
            $gltf[$key] = array_values($list);
        }
        $json = json_encode($gltf, JSON_UNESCAPED_SLASHES);
        if (!is_string($json)) {
            return ['ok' => false, 'message' => 'the model description could not be written again'];
        }
        return ['ok' => true, 'data' => self::pack($json, $newBin), 'images' => count($images)];
    }

    public static function encodeImage(string $toktx, string $bytes, string $workDir): array
    {
        if (!function_exists('imagecreatefromstring')) {
            return ['ok' => false, 'message' => 'the GD image module is missing'];
        }
        $image = @imagecreatefromstring($bytes);
        if ($image === false) {
            return ['ok' => false, 'message' => 'the photo could not be read'];
        }
        $width = imagesx($image);
        $height = imagesy($image);
        $fitWidth = max(4, intdiv($width, 4) * 4);
        $fitHeight = max(4, intdiv($height, 4) * 4);
        if ($fitWidth !== $width || $fitHeight !== $height) {
            $scaled = imagescale($image, $fitWidth, $fitHeight, IMG_BICUBIC);
            if ($scaled === false) {
                return ['ok' => false, 'message' => 'the photo could not be resized to a multiple of 4 pixels'];
            }
            $image = $scaled;
        }
        $stem = $workDir . '/' . bin2hex(random_bytes(8));
        $png = $stem . '.png';
        $ktx2 = $stem . '.ktx2';
        if (!imagepng($image, $png, 1)) {
            return ['ok' => false, 'message' => 'the photo could not be saved for the encoder'];
        }
        $command = [$toktx, '--t2', '--encode', 'uastc', '--uastc_quality', '2', '--uastc_rdo_l', '1.0', '--zcmp', '18', '--genmipmap', '--assign_oetf', 'srgb', $ktx2, $png];
        $run = self::run($command, self::IMAGE_TIMEOUT_S);
        @unlink($png);
        if (!$run['ok']) {
            @unlink($ktx2);
            return $run;
        }
        $data = @file_get_contents($ktx2);
        @unlink($ktx2);
        if (!is_string($data) || $data === '') {
            return ['ok' => false, 'message' => 'the encoder wrote no file'];
        }
        return ['ok' => true, 'data' => $data];
    }

    public static function parse(string $glb): array
    {
        if (strlen($glb) < 20) {
            return ['error' => 'the model is too short'];
        }
        $header = unpack('Vmagic/Vversion/Vlength', substr($glb, 0, 12));
        if ($header['magic'] !== 0x46546C67 || $header['version'] !== 2 || $header['length'] !== strlen($glb)) {
            return ['error' => 'the model is not a GLB 2.0 file'];
        }
        $chunk = unpack('VjsonLength/VjsonType', substr($glb, 12, 8));
        if ($chunk['jsonType'] !== 0x4E4F534A || 20 + $chunk['jsonLength'] > strlen($glb)) {
            return ['error' => 'the model has no JSON chunk'];
        }
        $json = json_decode(substr($glb, 20, $chunk['jsonLength']), true);
        if (!is_array($json)) {
            return ['error' => 'the model JSON does not parse'];
        }
        $at = 20 + $chunk['jsonLength'];
        $bin = '';
        if ($at + 8 <= strlen($glb)) {
            $binChunk = unpack('VbinLength/VbinType', substr($glb, $at, 8));
            if ($binChunk['binType'] !== 0x004E4942 || $at + 8 + $binChunk['binLength'] > strlen($glb)) {
                return ['error' => 'the model data chunk is broken'];
            }
            $bin = substr($glb, $at + 8, $binChunk['binLength']);
        }
        return ['json' => $json, 'bin' => $bin];
    }

    public static function pack(string $json, string $bin): string
    {
        $json .= str_repeat(' ', (4 - strlen($json) % 4) % 4);
        $bin .= str_repeat("\0", (4 - strlen($bin) % 4) % 4);
        $body = pack('VV', strlen($json), 0x4E4F534A) . $json;
        if ($bin !== '') {
            $body .= pack('VV', strlen($bin), 0x004E4942) . $bin;
        }
        return pack('VVV', 0x46546C67, 2, 12 + strlen($body)) . $body;
    }

    private static function run(array $command, int $timeoutS): array
    {
        $process = proc_open($command, [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
        if (!is_resource($process)) {
            return ['ok' => false, 'message' => 'the encoder could not be started'];
        }
        fclose($pipes[0]);
        stream_set_blocking($pipes[1], false);
        stream_set_blocking($pipes[2], false);
        $output = '';
        $started = microtime(true);
        while (true) {
            $output .= (string) stream_get_contents($pipes[1]) . (string) stream_get_contents($pipes[2]);
            $status = proc_get_status($process);
            if (!$status['running']) {
                $output .= (string) stream_get_contents($pipes[1]) . (string) stream_get_contents($pipes[2]);
                fclose($pipes[1]);
                fclose($pipes[2]);
                proc_close($process);
                $code = (int) $status['exitcode'];
                return $code === 0 ? ['ok' => true] : ['ok' => false, 'message' => "the encoder stopped with code $code: " . trim(substr($output, -300))];
            }
            if (microtime(true) - $started > $timeoutS) {
                proc_terminate($process, 9);
                fclose($pipes[1]);
                fclose($pipes[2]);
                proc_close($process);
                return ['ok' => false, 'message' => "the encoder took longer than $timeoutS s"];
            }
            usleep(50_000);
        }
    }
}
