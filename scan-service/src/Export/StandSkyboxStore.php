<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class StandSkyboxStore
{
    private const META = 'meta.json';

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
            return [filesize($path), filemtime($path)];
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
                    $ready[(string) $roomId][$index] = ['key' => $key, 'size' => (int) $meta['size']];
                } else {
                    $pending[] = ['room_id' => (string) $roomId, 'stand_id' => (string) ($stand['stand_id'] ?? ''), 'key' => $key, 'photos' => $photos];
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

    public function facePath(string $sessionId, string $key, string $face): ?string
    {
        if (!self::isKey($key) || !self::isFace($face) || $this->ready($sessionId, $key) === null) {
            return null;
        }
        $path = $this->dir($sessionId, $key) . '/' . $face . '.jpg';
        return is_file($path) ? $path : null;
    }

    public function build(string $sessionId, string $roomId, string $standId, string $key, array $photos, callable $photoPath): bool
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
                if ($path !== null && is_file($path)) {
                    $sources[] = ['photo' => $photo, 'bytes' => (string) file_get_contents($path)];
                }
            }
            $result = StandSkybox::render($sources);
            $dir = $this->dir($sessionId, $key);
            $tmp = $dir . '.tmp';
            $this->removeDir($tmp);
            if (!@mkdir($tmp, 0775, true)) {
                return false;
            }
            foreach ($result['faces'] as $face => $bytes) {
                file_put_contents($tmp . '/' . $face . '.jpg', $bytes);
            }
            file_put_contents($tmp . '/' . self::META, json_encode([
                'size' => $result['size'],
                'room_id' => $roomId,
                'stand_id' => $standId,
                'version' => StandSkybox::VERSION,
            ]));
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
