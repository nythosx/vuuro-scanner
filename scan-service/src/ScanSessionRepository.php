<?php

declare(strict_types=1);

namespace VuuroScan;

use PDO;

final class ScanSessionRepository
{
    /**
     * Default token lifetime and the caller-overridable bounds around it.
     * 90 days matches a typical pilot engagement length; the bounds stop a
     * caller from requesting an effectively permanent token (>1 year) or
     * one so short it can't survive a single on-site capture session
     * (<60 seconds).
     */
    public const DEFAULT_TOKEN_TTL_SECONDS = 90 * 24 * 60 * 60;
    public const MIN_TOKEN_TTL_SECONDS = 60;
    public const MAX_TOKEN_TTL_SECONDS = 365 * 24 * 60 * 60;

    // Caps total photos/notes per session, independent of the per-5-minute
    // rate limit on the attach routes (which bounds pace, not total).
    // Matches RoomPlanSimulatorAdapter::MAX_SURFACES_PER_GROUP's own limit.
    public const MAX_PHOTOS_PER_SESSION = 500;
    public const MAX_NOTES_PER_SESSION = 500;

    // Caps total rooms per session across every capture() call, same
    // reasoning as MAX_PHOTOS_PER_SESSION/MAX_NOTES_PER_SESSION: the capture
    // route's rate limit (60 calls/5min, each up to
    // RoomPlanSimulatorAdapter::MAX_FLOORS=50 rooms) bounds pace, not total
    // -- a session left running never stopped growing on its own. 500 stays
    // well clear of any legitimate multi-room property scan.
    public const MAX_ROOMS_PER_SESSION = 500;

    // Retention window for rate_limit_events pruning. Must stay comfortably
    // above every window actually passed to rateLimited() in
    // public/index.php (300s hardcoded almost everywhere, 600s default for
    // session creation) so pruning never removes a row a live window still
    // needs to count.
    public const RATE_LIMIT_EVENT_RETENTION_SECONDS = 3600;

    /**
     * For exactly the rotate-token route, an expired-but-still-correct token
     * remains acceptable proof of past possession for a bounded window after
     * expiry — the only recovery path for a token that's expired, since
     * there's no login/admin path otherwise. Every OTHER route stays
     * hard-blocked at the instant of expiry.
     *
     * 7 days: short enough that "expired" still means something, long
     * enough to survive a landlord being away for a week.
     */
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
        int $tokenTtlSeconds = self::DEFAULT_TOKEN_TTL_SECONDS
    ): array {
        $id = self::uuid();
        $accessToken = self::uuid();
        $createdAt = gmdate('c');
        $expiresAt = gmdate('c', time() + $tokenTtlSeconds);
        $stmt = $this->db->prepare(
            'INSERT INTO scan_sessions (id, property_id, unit_id, organisation_id, purpose, created_at, status, access_token, occupied, consent_obtained, expires_at)
             VALUES (:id, :property_id, :unit_id, :organisation_id, :purpose, :created_at, :status, :access_token, :occupied, :consent_obtained, :expires_at)'
        );
        $stmt->execute([
            'id' => $id,
            'property_id' => $propertyId,
            'unit_id' => $unitId,
            'organisation_id' => $organisationId,
            'purpose' => $purpose,
            'created_at' => $createdAt,
            'status' => 'created',
            'access_token' => $accessToken,
            'occupied' => $occupied ? 1 : 0,
            'consent_obtained' => $consentObtained ? 1 : 0,
            'expires_at' => $expiresAt,
        ]);

        return $this->find($id);
    }

    /**
     * Issues a new access token (and a fresh expiry) for a session,
     * invalidating the old one immediately — a client can renew a token
     * before it expires without a session ever having to be re-created.
     */
    public function rotateToken(string $sessionId, int $tokenTtlSeconds = self::DEFAULT_TOKEN_TTL_SECONDS): array
    {
        $newToken = self::uuid();
        $expiresAt = gmdate('c', time() + $tokenTtlSeconds);
        $stmt = $this->db->prepare(
            'UPDATE scan_sessions SET access_token = :access_token, expires_at = :expires_at WHERE id = :id'
        );
        $stmt->execute([
            'access_token' => $newToken,
            'expires_at' => $expiresAt,
            'id' => $sessionId,
        ]);

        return $this->find($sessionId);
    }

    /**
     * True once `expires_at` has passed. A session created before this
     * column existed has expires_at = '' (see Database.php's ALTER TABLE
     * migration), which this treats as "no expiry recorded" rather than
     * "already expired."
     */
    public function isTokenExpired(array $session): bool
    {
        $expiresAt = $session['expires_at'] ?? '';
        if ($expiresAt === '') {
            return false;
        }
        return strtotime($expiresAt) < time();
    }

    /**
     * True once expires_at PLUS the rotate-token grace period has passed —
     * the hard cutoff even rotate-token itself cannot cross. A session with
     * no recorded expiry (see isTokenExpired()'s doc comment) is never
     * beyond it.
     */
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
            "SELECT id, property_id, unit_id, organisation_id, purpose, status, created_at, expires_at, occupied
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

    /** @return array<int, string> session ids whose token expired more than ROTATE_GRACE_PERIOD_SECONDS ago — permanently unreachable, since rotate-token itself is hard-blocked past that point. */
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

    /**
     * The session id alone (which can leak via URLs, logs, screenshots)
     * must never be sufficient to read or write a session — this is the
     * check every endpoint other than session creation must call before
     * doing anything else.
     */
    public function tokenMatches(array $session, ?string $presentedToken): bool
    {
        return $presentedToken !== null && hash_equals($session['access_token'], $presentedToken);
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

    /** @return array<int, array{action: string, outcome: string, occurred_at: string}> */
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

    /**
     * Guards against a lost-update race between two genuinely concurrent
     * writers to the same session's floor_plans row (e.g. two capture calls,
     * or a capture racing a photo/note attach) — appendCapture() and
     * appendToContractArray() are both read-then-modify-then-write, so
     * without a lock the second writer's SELECT could see a stale
     * pre-write snapshot and silently overwrite the first writer's change.
     *
     * `BEGIN IMMEDIATE` (not PDO's own beginTransaction(), which issues a
     * plain deferred `BEGIN` that doesn't take SQLite's write lock until the
     * first actual write) forces the lock at the START of the transaction —
     * before the read — so a second connection's own BEGIN IMMEDIATE has to
     * wait (via Database::connect()'s busy_timeout) until the first
     * transaction commits.
     */
    private function withWriteLock(callable $fn): mixed
    {
        $this->db->exec('BEGIN IMMEDIATE');
        try {
            $result = $fn();
            $this->db->exec('COMMIT');
            return $result;
        } catch (\Throwable $e) {
            $this->db->exec('ROLLBACK');
            throw $e;
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

    /**
     * How many rooms this session already has, so a second/third capture
     * call in the same multi-room session can hand the adapter the right
     * room-numbering offset. 0 for a session with no floor plan yet.
     */
    public function roomCount(string $sessionId): int
    {
        $floorPlan = $this->findFloorPlan($sessionId);
        return $floorPlan === null ? 0 : count($floorPlan['rooms']);
    }

    /**
     * Appends the rooms from a newly-adapted capture onto the session's
     * existing FloorPlan (if any), rather than overwriting it — this is what
     * makes a multi-room session possible: each guided RoomPlan capture
     * covers one room, and this is the seam that stitches them into one
     * coherent result. photos/notes are preserved from the existing record;
     * captured_at advances to this capture's timestamp so it always
     * reflects the most recent room added.
     */
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

            $merged = $existing;
            $merged['rooms'] = array_merge($existing['rooms'], $newFloorPlan['rooms']);
            $merged['captured_at'] = $newFloorPlan['captured_at'];
            $merged['capture_provider'] = $newFloorPlan['capture_provider'];
            // Session-wide, set once — a later capture with no location never nulls out an earlier real one.
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

    /**
     * Photos/notes attach to the same unit package — both live inside the
     * same floor_plans row/contract_json as rooms, never a side table
     * joined only by convention.
     */
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

    /**
     * A caller-supplied room_id, when present, must actually name a room
     * that exists on this session — a typo'd or stale room_id is rejected
     * rather than silently stored as if it were a real association.
     */
    private function appendToContractArray(string $sessionId, string $field, array $item, int $maxCount): array
    {
        return $this->withWriteLock(function () use ($sessionId, $field, $item, $maxCount) {
            $floorPlan = $this->findFloorPlan($sessionId);
            if ($floorPlan === null) {
                throw new \RuntimeException(
                    "Cannot attach a $field to scan session $sessionId before it has a captured FloorPlan."
                );
            }

            // Checked inside the write lock so two concurrent attaches can't
            // both pass the check against a stale count and land at
            // maxCount + 1.
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

    // Sentinel stored in idempotency_keys.response_json while a claimed key's
    // capture is still being processed — never valid JSON a real FloorPlan
    // would produce, so findIdempotentResponse() can tell "someone else is
    // mid-request" apart from "no one has ever recorded a real result yet."
    private const IDEMPOTENCY_PENDING_MARKER = '__pending__';

    /**
     * A mobile client on spotty on-site wifi may retry a capture upload
     * after never seeing the response to the first attempt. Without this, a
     * retried POST .../capture would append the same room twice. Returns
     * the previously-stored FloorPlan response if this exact (session, key)
     * pair was already fully processed. Returns null both when this key has
     * never been seen AND when it's currently claimed-but-still-processing
     * (see claimIdempotencyKey) — either way, the caller has no finished
     * result to hand back yet.
     */
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

    /**
     * Answers whether THIS request is the same request a given
     * Idempotency-Key was originally claimed for. A key reused with a
     * genuinely different body must not silently replay the first response.
     * Returns null if the key has never been seen at all (caller is free to
     * claim it); otherwise returns the fingerprint recorded at claim time —
     * including while still pending — so the caller can reject a mismatch
     * before ever touching response_json.
     */
    public function idempotencyKeyFingerprint(string $sessionId, string $idempotencyKey): ?string
    {
        $stmt = $this->db->prepare(
            'SELECT request_fingerprint FROM idempotency_keys WHERE scan_session_id = :session_id AND idempotency_key = :key'
        );
        $stmt->execute(['session_id' => $sessionId, 'key' => $idempotencyKey]);
        $row = $stmt->fetch(PDO::FETCH_ASSOC);
        return $row === false ? null : $row['request_fingerprint'];
    }

    /**
     * Atomically claims the right to actually run a capture for this
     * (session, key) pair. The UNIQUE constraint on (scan_session_id,
     * idempotency_key) is what makes this safe under real concurrency:
     * only one INSERT can win. Returns true if THIS call won the claim (it
     * must now do the real work and call completeIdempotencyKey), false if
     * another request already holds it (it must not touch appendCapture).
     */
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

    /**
     * Fills in the real result for a key this same request already won via
     * claimIdempotencyKey(). Only ever called by the claim's winner, so a
     * plain UPDATE (not another INSERT ... ON CONFLICT) is correct here.
     */
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

    /**
     * Releases a held idempotency claim (deletes the row) so the same key
     * can be used again. There is no side effect to protect on a failed
     * capture (no room was appended), so releasing on failure is safe. The
     * caller must only invoke this when it actually holds the claim;
     * calling it for a key this request never claimed would let an
     * unrelated caller's still-valid claim be deleted out from under them.
     */
    public function releaseIdempotencyKey(string $sessionId, string $idempotencyKey): void
    {
        $stmt = $this->db->prepare(
            'DELETE FROM idempotency_keys WHERE scan_session_id = :session_id AND idempotency_key = :key'
        );
        $stmt->execute(['session_id' => $sessionId, 'key' => $idempotencyKey]);
    }

    /**
     * Fixed-window rate limiter. `$bucket` is the caller's own composite key
     * (typically IP + route or session + route); counting and enforcement
     * are separate on purpose so a caller can check-then-record atomically
     * enough for a single-process PHP dev server without needing a separate
     * cache/lock service.
     */
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

        // Pruned every 100th insert, not every single one — id is SQLite
        // AUTOINCREMENT (monotonic, never reused, even across deletes), so
        // this is a deterministic, testable trigger rather than a
        // probabilistic one.
        $id = (int) $this->db->lastInsertId();
        if ($id % 100 === 0) {
            $this->pruneOldRateLimitEvents();
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
}
