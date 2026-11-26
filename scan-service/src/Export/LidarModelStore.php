<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class LidarModelStore
{
    public const MAX_BYTES = 120 * 1024 * 1024;
    public const MAX_CHUNK_BYTES = 6 * 1024 * 1024;
    private const MODEL = 'model.glb';
    private const PART = 'model.part';
    private const META = 'model.json';
    private const KTX2 = 'model-ktx2.glb';
    private const KTX2_PART = 'model-ktx2.part';
    private const KTX2_STATUS = 'model-ktx2.json';
    private const KTX2_LOCK = 'model-ktx2.lock';

    public function __construct(private readonly string $root)
    {
    }

    public function receivedBytes(string $sessionId): int
    {
        $part = $this->dir($sessionId) . '/' . self::PART;
        clearstatcache(true, $part);
        return is_file($part) ? (int) filesize($part) : 0;
    }

    public function appendChunk(string $sessionId, int $offset, int $total, string $bytes): array
    {
        if ($total <= 0 || $total > self::MAX_BYTES) {
            return ['ok' => false, 'status' => 413, 'code' => 'lidar_model_too_large', 'message' => 'The 3D model must be between 1 byte and ' . intdiv(self::MAX_BYTES, 1024 * 1024) . ' MB.'];
        }
        if ($bytes === '' || strlen($bytes) > self::MAX_CHUNK_BYTES) {
            return ['ok' => false, 'status' => 422, 'code' => 'bad_chunk', 'message' => 'Each chunk must hold 1 byte to ' . intdiv(self::MAX_CHUNK_BYTES, 1024 * 1024) . ' MB.'];
        }
        $received = $offset === 0 ? 0 : $this->receivedBytes($sessionId);
        if ($offset !== $received) {
            return ['ok' => false, 'status' => 409, 'code' => 'offset_mismatch', 'message' => "The server has $received bytes of this upload, not $offset.", 'received_bytes' => $received];
        }
        if ($offset + strlen($bytes) > $total) {
            return ['ok' => false, 'status' => 422, 'code' => 'chunk_past_total', 'message' => 'This chunk goes past the total size of the upload.'];
        }
        $dir = $this->dir($sessionId);
        if (!is_dir($dir) && !mkdir($dir, 0755, true) && !is_dir($dir)) {
            return ['ok' => false, 'status' => 500, 'code' => 'internal_error', 'message' => 'Could not create storage for the 3D model.'];
        }
        $written = file_put_contents($dir . '/' . self::PART, $bytes, $offset === 0 ? LOCK_EX : FILE_APPEND | LOCK_EX);
        if ($written !== strlen($bytes)) {
            return ['ok' => false, 'status' => 500, 'code' => 'internal_error', 'message' => 'Could not save this part of the 3D model.'];
        }
        return ['ok' => true, 'received_bytes' => $offset + $written];
    }

    public function complete(string $sessionId, int $total, string $sha256, array $info): array
    {
        $part = $this->dir($sessionId) . '/' . self::PART;
        $received = $this->receivedBytes($sessionId);
        if ($received !== $total) {
            return ['ok' => false, 'status' => 409, 'code' => 'upload_incomplete', 'message' => "The server has $received of $total bytes.", 'received_bytes' => $received];
        }
        $actual = hash_file('sha256', $part);
        if (!is_string($actual) || !hash_equals($actual, strtolower($sha256))) {
            @unlink($part);
            return ['ok' => false, 'status' => 422, 'code' => 'checksum_mismatch', 'message' => 'The uploaded 3D model does not match its checksum. Send it again.'];
        }
        $problem = self::glbProblem($part);
        if ($problem !== null) {
            @unlink($part);
            return ['ok' => false, 'status' => 422, 'code' => 'invalid_glb', 'message' => 'The uploaded file is not a usable 3D model: ' . $problem . '.'];
        }
        $model = $this->dir($sessionId) . '/' . self::MODEL;
        $this->forgetKtx2($sessionId);
        if (!rename($part, $model)) {
            return ['ok' => false, 'status' => 500, 'code' => 'internal_error', 'message' => 'Could not store the 3D model.'];
        }
        $meta = [
            'bytes' => $total,
            'sha256' => $actual,
            'uploaded_at' => gmdate('c'),
            'triangles' => isset($info['triangles']) && is_int($info['triangles']) && $info['triangles'] >= 0 ? $info['triangles'] : null,
            'photos' => isset($info['photos']) && is_int($info['photos']) && $info['photos'] >= 0 ? $info['photos'] : null,
            'capture' => isset($info['capture']) && is_string($info['capture']) ? substr($info['capture'], 0, 64) : null,
        ];
        if (file_put_contents($this->dir($sessionId) . '/' . self::META, json_encode($meta, JSON_UNESCAPED_SLASHES), LOCK_EX) === false) {
            return ['ok' => false, 'status' => 500, 'code' => 'internal_error', 'message' => 'Could not store the 3D model details.'];
        }
        return ['ok' => true, 'meta' => $meta];
    }

    public function modelPath(string $sessionId): ?string
    {
        $model = $this->dir($sessionId) . '/' . self::MODEL;
        return is_file($model) ? $model : null;
    }

    public function meta(string $sessionId): ?array
    {
        if ($this->modelPath($sessionId) === null) {
            return null;
        }
        $raw = @file_get_contents($this->dir($sessionId) . '/' . self::META);
        $meta = is_string($raw) ? json_decode($raw, true) : null;
        return is_array($meta) ? $meta : null;
    }

    public function ktx2Path(string $sessionId): ?string
    {
        $path = $this->dir($sessionId) . '/' . self::KTX2;
        clearstatcache(true, $path);
        return is_file($path) && $this->modelPath($sessionId) !== null ? $path : null;
    }

    public function ktx2Status(string $sessionId): ?array
    {
        $raw = @file_get_contents($this->dir($sessionId) . '/' . self::KTX2_STATUS);
        $status = is_string($raw) ? json_decode($raw, true) : null;
        return is_array($status) ? $status : null;
    }

    public function buildKtx2(string $sessionId, string $toktx, ?callable $encode = null): array
    {
        $dir = $this->dir($sessionId);
        $model = $this->modelPath($sessionId);
        if ($model === null) {
            return ['ok' => false, 'message' => 'no 3D model is stored for this session'];
        }
        $lock = @fopen($dir . '/' . self::KTX2_LOCK, 'c');
        if ($lock === false) {
            return ['ok' => false, 'message' => 'the compression lock could not be opened'];
        }
        if (!flock($lock, LOCK_EX)) {
            fclose($lock);
            return ['ok' => false, 'message' => 'the compression lock could not be taken'];
        }
        $started = microtime(true);
        $sha = hash_file('sha256', $model);
        $previous = $this->ktx2Status($sessionId);
        if ($this->ktx2Path($sessionId) !== null && ($previous['state'] ?? '') === 'done' && ($previous['source_sha256'] ?? '') === $sha) {
            flock($lock, LOCK_UN);
            fclose($lock);
            return ['ok' => true, 'bytes' => (int) ($previous['bytes'] ?? 0), 'photos' => (int) ($previous['photos'] ?? 0), 'seconds' => 0.0];
        }
        $this->writeKtx2Status($sessionId, ['state' => 'running', 'source_sha256' => $sha, 'started_at' => gmdate('c')]);
        $glb = @file_get_contents($model);
        $result = is_string($glb)
            ? LidarModelKtx2::rewrite($glb, $encode ?? fn (string $bytes): array => LidarModelKtx2::encodeImage($toktx, $bytes, $dir))
            : ['ok' => false, 'message' => 'the stored 3D model could not be read'];
        if ($result['ok'] && strlen($result['data']) > self::MAX_BYTES) {
            $result = ['ok' => false, 'message' => 'the compressed model is larger than ' . intdiv(self::MAX_BYTES, 1024 * 1024) . ' MB'];
        }
        if ($result['ok'] && hash_file('sha256', $model) !== $sha) {
            $result = ['ok' => false, 'message' => 'a newer 3D model arrived while compressing'];
        }
        if ($result['ok']) {
            $part = $dir . '/' . self::KTX2_PART;
            if (file_put_contents($part, $result['data'], LOCK_EX) !== strlen($result['data']) || !rename($part, $dir . '/' . self::KTX2)) {
                @unlink($part);
                $result = ['ok' => false, 'message' => 'the compressed model could not be saved'];
            }
        }
        $seconds = round(microtime(true) - $started, 1);
        $this->writeKtx2Status($sessionId, $result['ok']
            ? ['state' => 'done', 'source_sha256' => $sha, 'bytes' => strlen($result['data']), 'photos' => $result['images'], 'seconds' => $seconds, 'finished_at' => gmdate('c')]
            : ['state' => 'failed', 'source_sha256' => $sha, 'message' => $result['message'], 'seconds' => $seconds, 'finished_at' => gmdate('c')]);
        flock($lock, LOCK_UN);
        fclose($lock);
        return $result['ok'] ? ['ok' => true, 'bytes' => strlen($result['data']), 'photos' => $result['images'], 'seconds' => $seconds] : ['ok' => false, 'message' => $result['message']];
    }

    private function forgetKtx2(string $sessionId): void
    {
        foreach ([self::KTX2, self::KTX2_PART, self::KTX2_STATUS] as $name) {
            $path = $this->dir($sessionId) . '/' . $name;
            if (is_file($path)) {
                @unlink($path);
            }
        }
    }

    private function writeKtx2Status(string $sessionId, array $status): void
    {
        file_put_contents($this->dir($sessionId) . '/' . self::KTX2_STATUS, json_encode($status, JSON_UNESCAPED_SLASHES), LOCK_EX);
    }

    public function deleteSession(string $sessionId): void
    {
        $dir = $this->dir($sessionId);
        if (!is_dir($dir)) {
            return;
        }
        foreach (glob($dir . '/*') ?: [] as $file) {
            if (is_file($file)) {
                unlink($file);
            }
        }
        rmdir($dir);
    }

    public static function glbProblem(string $path): ?string
    {
        $handle = @fopen($path, 'rb');
        if ($handle === false) {
            return 'it could not be opened';
        }
        $header = fread($handle, 20);
        if (!is_string($header) || strlen($header) < 20) {
            fclose($handle);
            return 'it is too short';
        }
        $fields = unpack('Vmagic/Vversion/Vlength/VjsonLength/VjsonType', $header);
        if ($fields['magic'] !== 0x46546C67) {
            fclose($handle);
            return 'it is not a GLB file';
        }
        if ($fields['version'] !== 2) {
            fclose($handle);
            return 'it is not glTF 2.0';
        }
        clearstatcache(true, $path);
        if ($fields['length'] !== (int) filesize($path)) {
            fclose($handle);
            return 'its length field does not match the file size';
        }
        if ($fields['jsonType'] !== 0x4E4F534A || $fields['jsonLength'] <= 0 || $fields['jsonLength'] > 8 * 1024 * 1024 || 20 + $fields['jsonLength'] > $fields['length']) {
            fclose($handle);
            return 'its JSON chunk is missing';
        }
        $json = fread($handle, $fields['jsonLength']);
        fclose($handle);
        $gltf = is_string($json) ? json_decode($json, true) : null;
        if (!is_array($gltf)) {
            return 'its JSON chunk does not parse';
        }
        if (!is_array($gltf['meshes'] ?? null) || $gltf['meshes'] === []) {
            return 'it has no meshes';
        }
        if (!is_array($gltf['accessors'] ?? null) || !is_array($gltf['bufferViews'] ?? null)) {
            return 'it has no accessors';
        }
        return null;
    }

    private function dir(string $sessionId): string
    {
        return $this->root . '/' . preg_replace('/[^a-zA-Z0-9\-]/', '', $sessionId);
    }
}
