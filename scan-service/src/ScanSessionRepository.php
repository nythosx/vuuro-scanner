<?php

declare(strict_types=1);

namespace VuuroScan;

use PDO;

final class ScanSessionRepository
{

    public const DEFAULT_TOKEN_TTL_SECONDS = 90 * 24 * 60 * 60;
    public const MIN_TOKEN_TTL_SECONDS = 60;
    public const MAX_TOKEN_TTL_SECONDS = 365 * 24 * 60 * 60;

    public const MAX_PHOTOS_PER_SESSION = 500;
    public const MAX_NOTES_PER_SESSION = 500;

    public const MAX_ROOMS_PER_SESSION = 500;

    public const RATE_LIMIT_EVENT_RETENTION_SECONDS = 3600;

    public const ROTATE_GRACE_PERIOD_SECONDS = 7 * 24 * 60 * 60;

    public function __construct(private PDO $db)
    {
    }

    public function create(
        string $propertyId,
        string $unitId,
        string $organisationId,
        string $purpose,
        bool $occupied,
        bool $consentObtained,
        int $tokenTtlSeconds = self::DEFAULT_TOKEN_TTL_SECONDS,
        string $defaultFloor = ''
    ): array {
        $id = self::uuid();
        $accessToken = self::uuid();
        $createdAt = gmdate('c');
        $expiresAt = gmdate('c', time() + $tokenTtlSeconds);
        $stmt = $this->db->prepare(
            "INSERT INTO scan_sessions (id, property_id, unit_id, organisation_id, purpose, created_at, status, access_token, access_token_hash, occupied, consent_obtained, expires_at, default_floor)
             VALUES (:id, :property_id, :unit_id, :organisation_id, :purpose, :created_at, :status, '', :access_token_hash, :occupied, :consent_obtained, :expires_at, :default_floor)"
        );
        $stmt->execute([
            'id' => $id,
            'property_id' => $propertyId,
            'unit_id' => $unitId,
            'organisation_id' => $organisationId,
            'purpose' => $purpose,
            'created_at' => $createdAt,
            'status' => 'created',
            'access_token_hash' => hash('sha256', $accessToken),
            'occupied' => $occupied ? 1 : 0,
            'consent_obtained' => $consentObtained ? 1 : 0,
            'expires_at' => $expiresAt,
            'default_floor' => $defaultFloor,
        ]);

        return self::withPlaintextToken($this->find($id), $accessToken);
    }

    public function setDefaultFloor(string $sessionId, string $floor): array
    {
        $stmt = $this->db->prepare('UPDATE scan_sessions SET default_floor = :floor WHERE id = :id');
        $stmt->execute(['floor' => $floor, 'id' => $sessionId]);
        $session = $this->find($sessionId);
        return self::withPlaintextToken($session, '');
    }

    public function rotateToken(string $sessionId, int $tokenTtlSeconds = self::DEFAULT_TOKEN_TTL_SECONDS): array
    {
        $newToken = self::uuid();
        $expiresAt = gmdate('c', time() + $tokenTtlSeconds);
        $stmt = $this->db->prepare(
            "UPDATE scan_sessions SET access_token = '', access_token_hash = :access_token_hash, expires_at = :expires_at WHERE id = :id"
        );
        $stmt->execute([
            'access_token_hash' => hash('sha256', $newToken),
            'expires_at' => $expiresAt,
            'id' => $sessionId,
        ]);

        return self::withPlaintextToken($this->find($sessionId), $newToken);
    }

    private static function withPlaintextToken(array $session, string $token): array
    {
        unset($session['access_token_hash']);
        $session['access_token'] = $token;
        return $session;
    }

    public function isTokenExpired(array $session): bool
    {
        $expiresAt = $session['expires_at'] ?? '';
        if ($expiresAt === '') {
            return false;
        }
        return strtotime($expiresAt) < time();
    }

    public function isBeyondRotateGracePeriod(array $session): bool
    {
        $expiresAt = $session['expires_at'] ?? '';
        if ($expiresAt === '') {
            return false;
        }
        return strtotime($expiresAt) + self::ROTATE_GRACE_PERIOD_SECONDS < time();
    }

    public function find(string $id): ?array
    {
        $stmt = $this->db->prepare('SELECT * FROM scan_sessions WHERE id = :id');
        $stmt->execute(['id' => $id]);
        $row = $stmt->fetch(PDO::FETCH_ASSOC);
        return $row ?: null;
    }

    public function findByFilters(?string $propertyId, ?string $unitId, ?string $organisationId, int $limit = 100): array
    {
        $conditions = [];
        $params = [];
        if ($propertyId !== null) {
            $conditions[] = 'property_id = :property_id';
            $params['property_id'] = $propertyId;
        }
        if ($unitId !== null) {
            $conditions[] = 'unit_id = :unit_id';
            $params['unit_id'] = $unitId;
        }
        if ($organisationId !== null) {
            $conditions[] = 'organisation_id = :organisation_id';
            $params['organisation_id'] = $organisationId;
        }

        $where = $conditions === [] ? '' : 'WHERE ' . implode(' AND ', $conditions);
        $stmt = $this->db->prepare(
            "SELECT id, property_id, unit_id, organisation_id, purpose, status, created_at, expires_at, occupied, default_floor
             FROM scan_sessions $where ORDER BY created_at DESC LIMIT :limit"
        );
        foreach ($params as $key => $value) {
            $stmt->bindValue(":$key", $value, PDO::PARAM_STR);
        }
        $stmt->bindValue(':limit', $limit, PDO::PARAM_INT);
        $stmt->execute();
        return array_map(
            static fn (array $row) => [...$row, 'occupied' => (bool) $row['occupied']],
            $stmt->fetchAll(PDO::FETCH_ASSOC)
        );
    }

    public function deleteSession(string $id): void
    {
        $this->withWriteLock(function () use ($id) {
            $this->db->prepare('DELETE FROM floor_plans WHERE scan_session_id = :id')->execute(['id' => $id]);
            $this->db->prepare('DELETE FROM idempotency_keys WHERE scan_session_id = :id')->execute(['id' => $id]);
            $this->db->prepare('DELETE FROM access_log WHERE scan_session_id = :id')->execute(['id' => $id]);
            $this->db->prepare('DELETE FROM scan_sessions WHERE id = :id')->execute(['id' => $id]);
        });
    }

    public function findExpiredBeyondGracePeriod(int $limit = 20): array
    {
        $cutoff = gmdate('c', time() - self::ROTATE_GRACE_PERIOD_SECONDS);
        $stmt = $this->db->prepare("SELECT id FROM scan_sessions WHERE expires_at != '' AND expires_at < :cutoff LIMIT :limit");
        $stmt->bindValue(':cutoff', $cutoff, PDO::PARAM_STR);
        $stmt->bindValue(':limit', $limit, PDO::PARAM_INT);
        $stmt->execute();
        return array_column($stmt->fetchAll(PDO::FETCH_ASSOC), 'id');
    }

    public function findEarlyPurgeCandidates(string $purpose, int $retentionDays, int $limit = 20): array
    {
        $cutoff = gmdate('c', time() - $retentionDays * 86400);
        $stmt = $this->db->prepare('SELECT id FROM scan_sessions WHERE purpose = :purpose AND created_at < :cutoff LIMIT :limit');
        $stmt->bindValue(':purpose', $purpose, PDO::PARAM_STR);
        $stmt->bindValue(':cutoff', $cutoff, PDO::PARAM_STR);
        $stmt->bindValue(':limit', $limit, PDO::PARAM_INT);
        $stmt->execute();
        return array_column($stmt->fetchAll(PDO::FETCH_ASSOC), 'id');
    }

    public function lastInsertRowId(): int
    {
        return (int) $this->db->lastInsertId();
    }

    public function tokenMatches(array $session, ?string $presentedToken): bool
    {
        $storedHash = (string) ($session['access_token_hash'] ?? '');
        return $presentedToken !== null && $storedHash !== '' && hash_equals($storedHash, hash('sha256', $presentedToken));
    }

    public function logAccess(string $sessionId, string $action, string $outcome): void
    {
        $stmt = $this->db->prepare(
            'INSERT INTO access_log (scan_session_id, action, outcome, occurred_at) VALUES (:session_id, :action, :outcome, :occurred_at)'
        );
        $stmt->execute([
            'session_id' => $sessionId,
            'action' => $action,
            'outcome' => $outcome,
            'occurred_at' => gmdate('c'),
        ]);
    }

    public function accessLog(string $sessionId): array
    {
        $stmt = $this->db->prepare(
            'SELECT action, outcome, occurred_at FROM access_log WHERE scan_session_id = :id ORDER BY id ASC'
        );
        $stmt->execute(['id' => $sessionId]);
        return $stmt->fetchAll(PDO::FETCH_ASSOC);
    }

    public function markCaptured(string $id): void
    {
        $stmt = $this->db->prepare("UPDATE scan_sessions SET status = 'captured' WHERE id = :id");
        $stmt->execute(['id' => $id]);
    }

    private function withWriteLock(callable $fn): mixed
    {
        $attempts = 0;
        $maxAttempts = 3;
        while (true) {
            try {
                $this->db->exec('BEGIN IMMEDIATE');
            } catch (\PDOException $e) {
                if (str_contains($e->getMessage(), 'database is locked') && ++$attempts < $maxAttempts) {
                    usleep(100_000 * $attempts);
                    continue;
                }
                throw $e;
            }
            try {
                $result = $fn();
                $this->db->exec('COMMIT');
                return $result;
            } catch (\PDOException $e) {
                $this->db->exec('ROLLBACK');
                if (str_contains($e->getMessage(), 'database is locked') && ++$attempts < $maxAttempts) {
                    usleep(100_000 * $attempts);
                    continue;
                }
                throw $e;
            } catch (\Throwable $e) {
                $this->db->exec('ROLLBACK');
                throw $e;
            }
        }
    }

    public function saveFloorPlan(string $sessionId, array $floorPlan): void
    {
        $stmt = $this->db->prepare(
            'INSERT INTO floor_plans (scan_session_id, capture_provider, captured_at, measurement_basis, contract_json)
             VALUES (:scan_session_id, :capture_provider, :captured_at, :measurement_basis, :contract_json)
             ON CONFLICT(scan_session_id) DO UPDATE SET
                capture_provider = excluded.capture_provider,
                captured_at = excluded.captured_at,
                measurement_basis = excluded.measurement_basis,
                contract_json = excluded.contract_json'
        );
        $stmt->execute([
            'scan_session_id' => $sessionId,
            'capture_provider' => $floorPlan['capture_provider'],
            'captured_at' => $floorPlan['captured_at'],
            'measurement_basis' => $floorPlan['measurement_basis'],
            'contract_json' => json_encode($floorPlan, JSON_THROW_ON_ERROR),
        ]);
    }

    public function findFloorPlan(string $sessionId): ?array
    {
        $stmt = $this->db->prepare('SELECT contract_json FROM floor_plans WHERE scan_session_id = :id');
        $stmt->execute(['id' => $sessionId]);
        $row = $stmt->fetch(PDO::FETCH_ASSOC);
        if (!$row) {
            return null;
        }
        return json_decode($row['contract_json'], true, 512, JSON_THROW_ON_ERROR);
    }

    public function roomCount(string $sessionId): int
    {
        $floorPlan = $this->findFloorPlan($sessionId);
        return $floorPlan === null ? 0 : count($floorPlan['rooms']);
    }

    public function appendCapture(string $sessionId, array $newFloorPlan): array
    {
        return $this->withWriteLock(function () use ($sessionId, $newFloorPlan) {
            $existing = $this->findFloorPlan($sessionId);
            if ($existing === null) {
                $this->saveFloorPlan($sessionId, $newFloorPlan);
                return $newFloorPlan;
            }

            $mergedRoomCount = count($existing['rooms']) + count($newFloorPlan['rooms']);
            if ($mergedRoomCount > self::MAX_ROOMS_PER_SESSION) {
                throw new \OverflowException(
                    "This session already has " . count($existing['rooms']) . " of the maximum " . self::MAX_ROOMS_PER_SESSION . " rooms."
                );
            }

            $existingRoomIds = array_column($existing['rooms'], 'room_id');
            $newRoomIds = array_column($newFloorPlan['rooms'], 'room_id');
            $duplicateRoomIds = array_intersect($existingRoomIds, $newRoomIds);
            if (!empty($duplicateRoomIds)) {
                throw new \RuntimeException(
                    'Capture retried with room_id(s) already present on this session: ' . implode(', ', $duplicateRoomIds) . '. Refusing to merge to avoid corrupting an existing room.'
                );
            }

            $merged = $existing;
            $merged['rooms'] = array_merge($existing['rooms'], $newFloorPlan['rooms']);
            $merged['captured_at'] = $newFloorPlan['captured_at'];
            $merged['capture_provider'] = $newFloorPlan['capture_provider'];
            $merged['capture_location'] = $existing['capture_location'] ?? ($newFloorPlan['capture_location'] ?? null);

            $this->saveFloorPlan($sessionId, $merged);
            return $merged;
        });
    }

    public function replaceRooms(string $sessionId, array $rooms, string $captureProvider, string $capturedAt): array
    {
        return $this->withWriteLock(function () use ($sessionId, $rooms, $captureProvider, $capturedAt) {
            $existing = $this->findFloorPlan($sessionId);
            if ($existing === null) {
                throw new \RuntimeException(
                    "Cannot replace rooms on scan session $sessionId before it has a captured FloorPlan."
                );
            }
            if (count($rooms) > self::MAX_ROOMS_PER_SESSION) {
                throw new \OverflowException(
                    'Replacement room set has ' . count($rooms) . ' rooms, exceeding the ' . self::MAX_ROOMS_PER_SESSION . '-room limit.'
                );
            }

            $merged = $existing;
            $merged['rooms'] = $rooms;
            $merged['captured_at'] = $capturedAt;
            $merged['capture_provider'] = $captureProvider;

            $this->saveFloorPlan($sessionId, $merged);
            return $merged;
        });
    }

    public function appendPhoto(string $sessionId, array $photo): array
    {
        return $this->appendToContractArray($sessionId, 'photos', $photo, self::MAX_PHOTOS_PER_SESSION);
    }

    public function appendNote(string $sessionId, array $note): array
    {
        return $this->appendToContractArray($sessionId, 'notes', $note, self::MAX_NOTES_PER_SESSION);
    }

    public function deletePhoto(string $sessionId, string $photoId): array
    {
        return $this->deleteFromContractArray($sessionId, 'photos', 'photo_id', $photoId);
    }

    public function deleteNote(string $sessionId, string $noteId): array
    {
        return $this->deleteFromContractArray($sessionId, 'notes', 'note_id', $noteId);
    }

    public function updateNote(string $sessionId, string $noteId, string $text, ?array $tags = null): array
    {
        return $this->withWriteLock(function () use ($sessionId, $noteId, $text, $tags) {
            $floorPlan = $this->findFloorPlan($sessionId);
            if ($floorPlan === null) {
                throw new \RuntimeException(
                    "Cannot update a note on scan session $sessionId before it has a captured FloorPlan."
                );
            }

            $index = null;
            foreach ($floorPlan['notes'] as $i => $note) {
                if ($note['note_id'] === $noteId) {
                    $index = $i;
                    break;
                }
            }
            if ($index === null) {
                throw new \InvalidArgumentException(
                    "note_id '{$noteId}' does not match any note attached to this session."
                );
            }

            $floorPlan['notes'][$index]['text'] = $text;
            if ($tags !== null) {
                $floorPlan['notes'][$index]['tags'] = $tags;
            }
            $floorPlan['notes'][$index]['updated_at'] = gmdate('c');
            $this->saveFloorPlan($sessionId, $floorPlan);
            return $floorPlan;
        });
    }

    private function deleteFromContractArray(string $sessionId, string $field, string $idKey, string $id): array
    {
        return $this->withWriteLock(function () use ($sessionId, $field, $idKey, $id) {
            $floorPlan = $this->findFloorPlan($sessionId);
            if ($floorPlan === null) {
                throw new \RuntimeException(
                    "Cannot delete a $field from scan session $sessionId before it has a captured FloorPlan."
                );
            }

            $index = null;
            foreach ($floorPlan[$field] as $i => $item) {
                if ($item[$idKey] === $id) {
                    $index = $i;
                    break;
                }
            }
            if ($index === null) {
                throw new \InvalidArgumentException(
                    "$idKey '{$id}' does not match any $field attached to this session."
                );
            }

            array_splice($floorPlan[$field], $index, 1);
            $this->saveFloorPlan($sessionId, $floorPlan);
            return $floorPlan;
        });
    }

    private function appendToContractArray(string $sessionId, string $field, array $item, int $maxCount): array
    {
        return $this->withWriteLock(function () use ($sessionId, $field, $item, $maxCount) {
            $floorPlan = $this->findFloorPlan($sessionId);
            if ($floorPlan === null) {
                throw new \RuntimeException(
                    "Cannot attach a $field to scan session $sessionId before it has a captured FloorPlan."
                );
            }

            if (count($floorPlan[$field]) >= $maxCount) {
                throw new \OverflowException(
                    "This session already has the maximum of $maxCount {$field} attached."
                );
            }

            if (isset($item['room_id']) && $item['room_id'] !== null) {
                $knownRoomIds = array_column($floorPlan['rooms'], 'room_id');
                if (!in_array($item['room_id'], $knownRoomIds, true)) {
                    throw new \InvalidArgumentException(
                        "room_id '{$item['room_id']}' does not match any room captured in this session."
                    );
                }
            }

            $floorPlan[$field][] = $item;
            $this->saveFloorPlan($sessionId, $floorPlan);
            return $floorPlan;
        });
    }

    public function updateRoomType(string $sessionId, string $roomId, ?string $confirmed): array
    {
        return $this->withWriteLock(function () use ($sessionId, $roomId, $confirmed) {
            $floorPlan = $this->findFloorPlan($sessionId);
            if ($floorPlan === null) {
                throw new \RuntimeException(
                    "Cannot update a room's type on scan session $sessionId before it has a captured FloorPlan."
                );
            }

            $index = null;
            foreach ($floorPlan['rooms'] as $i => $room) {
                if ($room['room_id'] === $roomId) {
                    $index = $i;
                    break;
                }
            }
            if ($index === null) {
                throw new \InvalidArgumentException(
                    "room_id '{$roomId}' does not match any room captured in this session."
                );
            }

            $existing = $floorPlan['rooms'][$index]['room_type'] ?? [];
            $floorPlan['rooms'][$index]['room_type'] = [...$existing, 'confirmed' => $confirmed];
            $this->saveFloorPlan($sessionId, $floorPlan);
            return $floorPlan;
        });
    }

    public function updateRoomLabel(string $sessionId, string $roomId, string $label): array
    {
        return $this->withWriteLock(function () use ($sessionId, $roomId, $label) {
            $floorPlan = $this->findFloorPlan($sessionId);
            if ($floorPlan === null) {
                throw new \RuntimeException(
                    "Cannot rename a room on scan session $sessionId before it has a captured FloorPlan."
                );
            }

            $index = null;
            foreach ($floorPlan['rooms'] as $i => $room) {
                if ($room['room_id'] === $roomId) {
                    $index = $i;
                    break;
                }
            }
            if ($index === null) {
                throw new \InvalidArgumentException(
                    "room_id '{$roomId}' does not match any room captured in this session."
                );
            }

            $floorPlan['rooms'][$index]['label'] = $label;
            $this->saveFloorPlan($sessionId, $floorPlan);
            return $floorPlan;
        });
    }

    public function batchUpdateObjects(string $sessionId, array $changes): array
    {
        return $this->withWriteLock(function () use ($sessionId, $changes) {
            $floorPlan = $this->findFloorPlan($sessionId);
            if ($floorPlan === null) {
                throw new \RuntimeException(
                    "Cannot update objects on scan session $sessionId before it has a captured FloorPlan."
                );
            }

            foreach ($changes as $change) {
                $roomId = (string) $change['room_id'];
                $objectId = (string) $change['object_id'];

                $roomIndex = null;
                foreach ($floorPlan['rooms'] as $i => $room) {
                    if ($room['room_id'] === $roomId) {
                        $roomIndex = $i;
                        break;
                    }
                }
                if ($roomIndex === null) {
                    throw new \InvalidArgumentException("room_id '{$roomId}' does not match any room captured in this session.");
                }

                $objectIndex = null;
                $objects = $floorPlan['rooms'][$roomIndex]['objects'] ?? [];
                foreach ($objects as $j => $object) {
                    if ($object['object_id'] === $objectId) {
                        $objectIndex = $j;
                        break;
                    }
                }
                if ($objectIndex === null) {
                    if (!empty($change['delete'])) {
                        continue;
                    }
                    throw new \InvalidArgumentException("object_id '{$objectId}' does not match any object in room '{$roomId}'.");
                }

                if (!empty($change['delete'])) {
                    array_splice($floorPlan['rooms'][$roomIndex]['objects'], $objectIndex, 1);
                    continue;
                }

                if (array_key_exists('custom_name', $change)) {
                    $name = $change['custom_name'];
                    if ($name !== null) {
                        $name = trim((string) $name);
                        if ($name === '') {
                            $name = null;
                        } elseif (mb_strlen($name, 'UTF-8') > 60) {
                            throw new \InvalidArgumentException('Custom object name must be 60 characters or fewer.');
                        }
                    }
                    $floorPlan['rooms'][$roomIndex]['objects'][$objectIndex]['custom_name'] = $name;
                }
                if (array_key_exists('excluded', $change)) {
                    $floorPlan['rooms'][$roomIndex]['objects'][$objectIndex]['excluded'] = (bool) $change['excluded'];
                }
            }

            $this->saveFloorPlan($sessionId, $floorPlan);
            return $floorPlan;
        });
    }

    private const IDEMPOTENCY_PENDING_MARKER = '__pending__';


    public function findIdempotentResponse(string $sessionId, string $idempotencyKey): ?array
    {
        $stmt = $this->db->prepare(
            'SELECT response_json FROM idempotency_keys WHERE scan_session_id = :session_id AND idempotency_key = :key'
        );
        $stmt->execute(['session_id' => $sessionId, 'key' => $idempotencyKey]);
        $row = $stmt->fetch(PDO::FETCH_ASSOC);
        if (!$row || $row['response_json'] === self::IDEMPOTENCY_PENDING_MARKER) {
            return null;
        }
        return json_decode($row['response_json'], true, 512, JSON_THROW_ON_ERROR);
    }

    public function idempotencyKeyFingerprint(string $sessionId, string $idempotencyKey): ?string
    {
        $stmt = $this->db->prepare(
            'SELECT request_fingerprint FROM idempotency_keys WHERE scan_session_id = :session_id AND idempotency_key = :key'
        );
        $stmt->execute(['session_id' => $sessionId, 'key' => $idempotencyKey]);
        $row = $stmt->fetch(PDO::FETCH_ASSOC);
        return $row === false ? null : $row['request_fingerprint'];
    }

    public function claimIdempotencyKey(string $sessionId, string $idempotencyKey, string $requestFingerprint): bool
    {
        $stmt = $this->db->prepare(
            'INSERT INTO idempotency_keys (scan_session_id, idempotency_key, response_json, request_fingerprint, created_at)
             VALUES (:session_id, :key, :pending, :fingerprint, :created_at)
             ON CONFLICT(scan_session_id, idempotency_key) DO NOTHING'
        );
        $stmt->execute([
            'session_id' => $sessionId,
            'key' => $idempotencyKey,
            'pending' => self::IDEMPOTENCY_PENDING_MARKER,
            'fingerprint' => $requestFingerprint,
            'created_at' => gmdate('c'),
        ]);
        return $stmt->rowCount() === 1;
    }

    public function completeIdempotencyKey(string $sessionId, string $idempotencyKey, array $response): void
    {
        $stmt = $this->db->prepare(
            'UPDATE idempotency_keys SET response_json = :response_json
             WHERE scan_session_id = :session_id AND idempotency_key = :key'
        );
        $stmt->execute([
            'session_id' => $sessionId,
            'key' => $idempotencyKey,
            'response_json' => json_encode($response, JSON_THROW_ON_ERROR),
        ]);
    }

    public function releaseIdempotencyKey(string $sessionId, string $idempotencyKey): void
    {
        $stmt = $this->db->prepare(
            'DELETE FROM idempotency_keys WHERE scan_session_id = :session_id AND idempotency_key = :key'
        );
        $stmt->execute(['session_id' => $sessionId, 'key' => $idempotencyKey]);
    }

    public function countRecentEvents(string $bucket, int $windowSeconds): int
    {
        $cutoff = gmdate('c', time() - $windowSeconds);
        $stmt = $this->db->prepare(
            'SELECT COUNT(*) FROM rate_limit_events WHERE bucket = :bucket AND occurred_at >= :cutoff'
        );
        $stmt->execute(['bucket' => $bucket, 'cutoff' => $cutoff]);
        return (int) $stmt->fetchColumn();
    }

    public function recordEvent(string $bucket): void
    {
        $stmt = $this->db->prepare(
            'INSERT INTO rate_limit_events (bucket, occurred_at) VALUES (:bucket, :occurred_at)'
        );
        $stmt->execute(['bucket' => $bucket, 'occurred_at' => gmdate('c')]);

        $id = (int) $this->db->lastInsertId();
        if ($id % 100 === 0) {
            $this->pruneOldRateLimitEvents();
        }
    }

    public function recordAndCountRecentEvents(string $bucket, int $windowSeconds): int
    {
        $this->db->exec('BEGIN IMMEDIATE');
        try {
            $this->recordEvent($bucket);
            $count = $this->countRecentEvents($bucket, $windowSeconds);
            $this->db->exec('COMMIT');
            return $count;
        } catch (\Throwable $e) {
            $this->db->exec('ROLLBACK');
            throw $e;
        }
    }

    private function pruneOldRateLimitEvents(): void
    {
        $cutoff = gmdate('c', time() - self::RATE_LIMIT_EVENT_RETENTION_SECONDS);
        $stmt = $this->db->prepare('DELETE FROM rate_limit_events WHERE occurred_at < :cutoff');
        $stmt->execute(['cutoff' => $cutoff]);
    }

    public static function uuid(): string
    {
        $data = random_bytes(16);
        $data[6] = chr((ord($data[6]) & 0x0f) | 0x40);
        $data[8] = chr((ord($data[8]) & 0x3f) | 0x80);
        return vsprintf('%s%s-%s-%s-%s-%s%s%s', str_split(bin2hex($data), 4));
    }

    public function insertImportedScan(array $record): array
    {
        $stmt = $this->db->prepare(
            'INSERT INTO imported_scans (
                import_id, format, exported_at, imported_at, scan_service_base_url,
                session_id, property_id, unit_id, organisation_id, purpose,
                signature_status, signature_algorithm, payload_json
            ) VALUES (
                :import_id, :format, :exported_at, :imported_at, :scan_service_base_url,
                :session_id, :property_id, :unit_id, :organisation_id, :purpose,
                :signature_status, :signature_algorithm, :payload_json
            )'
        );
        $stmt->execute([
            'import_id' => $record['import_id'],
            'format' => $record['format'],
            'exported_at' => $record['exported_at'],
            'imported_at' => $record['imported_at'],
            'scan_service_base_url' => $record['scan_service_base_url'],
            'session_id' => $record['session_id'],
            'property_id' => $record['property_id'],
            'unit_id' => $record['unit_id'],
            'organisation_id' => $record['organisation_id'],
            'purpose' => $record['purpose'],
            'signature_status' => $record['signature_status'],
            'signature_algorithm' => $record['signature_algorithm'],
            'payload_json' => $record['payload_json'],
        ]);

        return [
            'import_id' => $record['import_id'],
            'format' => $record['format'],
            'exported_at' => $record['exported_at'],
            'imported_at' => $record['imported_at'],
            'scan_service_base_url' => $record['scan_service_base_url'],
            'session_id' => $record['session_id'],
            'property_id' => $record['property_id'],
            'unit_id' => $record['unit_id'],
            'organisation_id' => $record['organisation_id'],
            'purpose' => $record['purpose'],
            'signature_status' => $record['signature_status'],
            'signature_algorithm' => $record['signature_algorithm'],
        ];
    }

    public function findImportedScans(?string $propertyId, ?string $unitId, ?string $organisationId, int $limit = 100): array
    {
        $conditions = [];
        $params = [];
        if ($propertyId !== null) {
            $conditions[] = 'property_id = :property_id';
            $params['property_id'] = $propertyId;
        }
        if ($unitId !== null) {
            $conditions[] = 'unit_id = :unit_id';
            $params['unit_id'] = $unitId;
        }
        if ($organisationId !== null) {
            $conditions[] = 'organisation_id = :organisation_id';
            $params['organisation_id'] = $organisationId;
        }

        $where = $conditions === [] ? '' : 'WHERE ' . implode(' AND ', $conditions);
        $stmt = $this->db->prepare(
            "SELECT import_id, format, exported_at, imported_at, scan_service_base_url,
                    session_id, property_id, unit_id, organisation_id, purpose,
                    signature_status, signature_algorithm
             FROM imported_scans $where
             ORDER BY imported_at DESC
             LIMIT :limit"
        );
        foreach ($params as $key => $value) {
            $stmt->bindValue(":$key", $value, PDO::PARAM_STR);
        }
        $stmt->bindValue(':limit', $limit, PDO::PARAM_INT);
        $stmt->execute();
        return $stmt->fetchAll(PDO::FETCH_ASSOC);
    }

    public function findImportedScan(string $importId): ?array
    {
        $stmt = $this->db->prepare(
            'SELECT import_id, format, exported_at, imported_at, scan_service_base_url,
                    session_id, property_id, unit_id, organisation_id, purpose,
                    signature_status, signature_algorithm, payload_json
             FROM imported_scans WHERE import_id = :id'
        );
        $stmt->execute(['id' => $importId]);
        $row = $stmt->fetch(PDO::FETCH_ASSOC);
        if (!$row) {
            return null;
        }
        $payload = json_decode((string) $row['payload_json'], true, 512, JSON_THROW_ON_ERROR);
        unset($row['payload_json']);
        $row['payload'] = $payload;
        return $row;
    }
}