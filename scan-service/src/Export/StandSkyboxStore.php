<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class StandSkyboxStore
{
    private const META = 'meta.json';
    public const DEPTH_FILE = 'depth.bin.gz';

    public function __construct(private readonly string $root)
    {
    }

    public static function isKey(string $key): bool
    {
        return preg_match('/^[a-f0-9]{24}$/', $key) === 1;
    }

    public static function isFace(string $face): bool
    {
        return in_array($face, StandSkybox::FACES, true);
    }

    public function keyFor(array $photos, callable $photoPath): string
    {
        return StandSkybox::cacheKey($photos, static function (string $url) use ($photoPath): ?array {
            $path = $photoPath($url);
            if ($path === null || !is_file($path)) {
                return null;
            }
            $depth = self::depthFileFor($path);
            return [filesize($path), filemtime($path), $depth !== null ? filesize($depth) : null];
        });
    }

    public function plan(string $sessionId, array $standsByRoom, array $photosByRoom, callable $photoPath): array
    {
        $ready = [];
        $pending = [];
        foreach ($standsByRoom as $roomId => $stands) {
            $photoById = [];
            foreach ($photosByRoom[(string) $roomId] ?? [] as $photo) {
                $photoById[(string) ($photo['photo_id'] ?? '')] = $photo;
            }
            foreach ($stands as $index => $stand) {
                $photos = [];
                foreach ($stand['photo_ids'] ?? [] as $photoId) {
                    if (isset($photoById[(string) $photoId])) {
                        $photos[] = $photoById[(string) $photoId];
                    }
                }
                if (count($photos) < TourStands::MIN_PHOTOS_FOR_LOOK_AROUND) {
                    continue;
                }
                $key = $this->keyFor($photos, $photoPath);
                $meta = $this->ready($sessionId, $key);
                if ($meta !== null) {
                    $ready[(string) $roomId][$index] = ['key' => $key, 'size' => (int) $meta['size'], 'depth' => self::usableDepth($meta)];
                } else {
                    $centerXZ = is_array($stand['center_m'] ?? null) && count($stand['center_m']) >= 2 ? [(float) $stand['center_m'][0], (float) $stand['center_m'][1]] : null;
                    $pending[] = ['room_id' => (string) $roomId, 'stand_id' => (string) ($stand['stand_id'] ?? ''), 'key' => $key, 'photos' => $photos, 'center_m' => $centerXZ];
                }
            }
        }
        return ['ready' => $ready, 'pending' => $pending];
    }

    public function ready(string $sessionId, string $key): ?array
    {
        $meta = $this->dir($sessionId, $key) . '/' . self::META;
        if (!is_file($meta)) {
            return null;
        }
        $data = json_decode((string) file_get_contents($meta), true);
        return is_array($data) && isset($data['size']) ? $data : null;
    }

    public static function usableDepth(array $meta): ?array
    {
        $depth = $meta['depth'] ?? null;
        if (($meta['depth_version'] ?? null) !== StandDepthCube::VERSION || !is_array($depth)) {
            return null;
        }
        if ((float) ($depth['coverage'] ?? 0) < StandDepthCube::MIN_COVERAGE || !is_array($depth['center_m'] ?? null) || count($depth['center_m']) !== 3) {
            return null;
        }
        return ['size' => (int) $depth['size'], 'center_m' => array_map('floatval', $depth['center_m'])];
    }

    public function depthPath(string $sessionId, string $key): ?string
    {
        if (!self::isKey($key)) {
            return null;
        }
        $meta = $this->ready($sessionId, $key);
        if ($meta === null || self::usableDepth($meta) === null) {
            return null;
        }
        $path = $this->dir($sessionId, $key) . '/' . self::DEPTH_FILE;
        return is_file($path) ? $path : null;
    }

    public function facePath(string $sessionId, string $key, string $face): ?string
    {
        if (!self::isKey($key) || !self::isFace($face) || $this->ready($sessionId, $key) === null) {
            return null;
        }
        $path = $this->dir($sessionId, $key) . '/' . $face . '.jpg';
        return is_file($path) ? $path : null;
    }

    public function build(string $sessionId, string $roomId, string $standId, string $key, array $photos, callable $photoPath, ?array $centerXZ = null): bool
    {
        if ($this->ready($sessionId, $key) !== null) {
            return true;
        }
        $sessionDir = $this->sessionDir($sessionId);
        if (!is_dir($sessionDir) && !@mkdir($sessionDir, 0775, true) && !is_dir($sessionDir)) {
            return false;
        }
        $lock = fopen($sessionDir . '/.lock', 'c');
        if ($lock === false) {
            return false;
        }
        try {
            if (!flock($lock, LOCK_EX | LOCK_NB)) {
                return false;
            }
            if ($this->ready($sessionId, $key) !== null) {
                return true;
            }
            $sources = [];
            foreach ($photos as $photo) {
                $path = $photoPath((string) ($photo['url'] ?? ''));
                if ($path === null || !is_file($path)) {
                    continue;
                }
                $source = ['photo' => $photo, 'bytes' => (string) file_get_contents($path), 'depth' => null];
                $depthFile = ($photo['has_depth'] ?? false) === true ? self::depthFileFor($path) : null;
                if ($depthFile !== null) {
                    $depthBytes = (string) file_get_contents($depthFile);
                    if (StandDepthCube::usable($photo, $depthBytes)) {
                        $source['depth'] = $depthBytes;
                    }
                }
                $sources[] = $source;
            }
            $dir = $this->dir($sessionId, $key);
            $tmp = $dir . '.tmp';
            $this->removeDir($tmp);
            if (!@mkdir($tmp, 0775, true)) {
                return false;
            }
            $meta = ['depth_version' => StandDepthCube::VERSION, 'depth' => null];
            $depthForStitch = null;
            $depthSources = array_values(array_filter($sources, static fn (array $s): bool => $s['depth'] !== null));
            if ($centerXZ !== null && $depthSources !== []) {
                $cube = StandDepthCube::render(
                    array_map(static fn (array $s): array => ['photo' => $s['photo'], 'bytes' => $s['depth']], $depthSources),
                    StandDepthCube::center($centerXZ, $photos)
                );
                $gz = gzencode($cube['bytes'], 6);
                if ($gz !== false && file_put_contents($tmp . '/' . self::DEPTH_FILE, $gz) !== false) {
                    $meta['depth'] = [
                        'size' => $cube['size'],
                        'center_m' => $cube['center_m'],
                        'photos' => $cube['photos'],
                        'measured' => $cube['measured'],
                        'coverage' => $cube['coverage'],
                    ];
                }
                $depthForStitch = ['size' => $cube['size'], 'values' => $cube['values'], 'center' => $cube['center_m']];
                unset($cube);
            }
            $result = StandSkybox::render($sources, null, $depthForStitch);
            foreach ($result['faces'] as $face => $bytes) {
                file_put_contents($tmp . '/' . $face . '.jpg', $bytes);
            }
            file_put_contents($tmp . '/' . self::META, json_encode(array_merge([
                'size' => $result['size'],
                'room_id' => $roomId,
                'stand_id' => $standId,
                'version' => StandSkybox::VERSION,
                'gains' => $result['gains'],
            ], $meta)));
            $this->removeDir($dir);
            if (!@rename($tmp, $dir)) {
                $this->removeDir($tmp);
                return false;
            }
            $this->removeStale($sessionId, $roomId, $standId, $key);
            return true;
        } catch (\InvalidArgumentException $e) {
            return false;
        } finally {
            flock($lock, LOCK_UN);
            fclose($lock);
        }
    }

    public static function depthFileFor(?string $photoFile): ?string
    {
        if ($photoFile === null) {
            return null;
        }
        $path = preg_replace('#\.[A-Za-z0-9]+$#', '.depth', $photoFile);
        return is_string($path) && $path !== $photoFile && is_file($path) ? $path : null;
    }

    public function deleteSession(string $sessionId): void
    {
        $this->removeDir($this->sessionDir($sessionId));
    }

    private function removeStale(string $sessionId, string $roomId, string $standId, string $keepKey): void
    {
        foreach (glob($this->sessionDir($sessionId) . '/*', GLOB_ONLYDIR) ?: [] as $dir) {
            $key = basename($dir);
            if ($key === $keepKey || !self::isKey($key)) {
                continue;
            }
            $meta = json_decode((string) @file_get_contents($dir . '/' . self::META), true);
            if (is_array($meta) && ($meta['room_id'] ?? null) === $roomId && ($meta['stand_id'] ?? null) === $standId) {
                $this->removeDir($dir);
            }
        }
    }

    private function sessionDir(string $sessionId): string
    {
        return $this->root . '/' . $sessionId;
    }

    private function dir(string $sessionId, string $key): string
    {
        return $this->sessionDir($sessionId) . '/' . $key;
    }

    private function removeDir(string $dir): void
    {
        if (!is_dir($dir)) {
            return;
        }
        foreach (scandir($dir) ?: [] as $entry) {
            if ($entry === '.' || $entry === '..') {
                continue;
            }
            $path = $dir . '/' . $entry;
            if (is_dir($path) && !is_link($path)) {
                $this->removeDir($path);
            } else {
                @unlink($path);
            }
        }
        @rmdir($dir);
    }
}
