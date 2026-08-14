<?php

declare(strict_types=1);

namespace VuuroScan;

use PDO;

final class ScanSessionRepository
{
    /**
     * Default token lifetime and the caller-overridable bounds around it
     * (enterprise hardening — docs/adr/0003 flagged "no token rotation/
     * expiry" as a known limit). 90 days matches a typical pilot engagement
     * length; the bounds stop a caller from requesting an effectively
     * permanent token (>1 year) or one so short it can't survive a single
     * on-site capture session (<60 seconds).
     */
    public const DEFAULT_TOKEN_TTL_SECONDS = 90 * 24 * 60 * 60;
    public const MIN_TOKEN_TTL_SECONDS = 60;
    public const MAX_TOKEN_TTL_SECONDS = 365 * 24 * 60 * 60;

    /**
     * Closes the permanent-lockout gap flagged in README's "Known limits":
     * once a token expired, rotate-token was unreachable too (authorizeSession
     * blocked expired tokens on every route, including rotate-token's own),
     * and there is no login/admin recovery path — a landlord could
     * permanently lose access to a session's rooms/photos/notes.
     *
     * Fix, scoped deliberately narrow: for exactly the rotate-token route,
     * an expired-but-still-correct token remains acceptable proof of past
     * possession for a bounded window after expiry. Every OTHER route stays
     * hard-blocked at the instant of expiry, unchanged — this constant only
     * ever widens what rotate-token itself accepts, never any other action,
     * so it does not weaken the enumeration/security posture
     * authorizeSession() otherwise maintains.
     *
     * 7 days is a conservative default — short enough that "expired" still
     * means something (a token missing its own renewal window by more than
     * a week is a stale/abandoned session, not an active one that just
     * hasn't gotten around to rotating yet), while long enough to survive a
     * landlord being on holiday for a week without permanently losing a
     * session. Confirmed with Mark (2026-08-14): fine as the default for
     * this window, document it as such, tighten later if real pilot usage
     * shows it's wrong.
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
     * before it expires without a session ever having to be re-created
     * (which would otherwise mean losing the ability to resume the same
     * "unit story" — PHASES.md Phase 2 — under the old token).
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
     * "already expired" — never silently lock out data captured before the
     * hardening landed.
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
     * the hard cutoff even rotate-token itself cannot cross. See
     * ROTATE_GRACE_PERIOD_SECONDS for why this window exists and why it's
     * scoped to rotate-token only. A session with no recorded expiry (see
     * isTokenExpired()'s doc comment) is never beyond it.
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

    /**
     * Privacy by design (hard constraint #3): the session id alone (which
     * can leak via URLs, logs, screenshots) must never be sufficient to
     * read or write a session — this is the check every endpoint other than
     * session creation must call before doing anything else.
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
     * Closes a real lost-update race, found by deliberately probing the
     * adjacent case to the idempotency-claim race fix: that fix only
     * protects two requests sharing the SAME Idempotency-Key. It does
     * nothing for two genuinely DIFFERENT concurrent writes to one session's
     * floor_plans row — e.g. two capture calls with no shared key, or a
     * capture racing a photo/note attach. appendCapture() and
     * appendToContractArray() are both a plain read-then-modify-then-write:
     * findFloorPlan() (SELECT), merge in PHP, saveFloorPlan() (INSERT ...
     * ON CONFLICT DO UPDATE). If two callers' SELECTs both land before
     * either's write, the second write silently overwrites the first's
     * entire contract_json — not a double-append, a genuine loss: the first
     * caller's room/photo/note vanishes with no error on either side.
     * Reproduced deterministically (not by real thread timing) at the
     * repository-test layer by manually inlining these same steps with two
     * interleaved find-then-save sequences — see tests/repository_test.php's
     * "concurrent capture race" section for the before/after proof.
     *
     * `BEGIN IMMEDIATE` (not PDO's own beginTransaction(), which issues a
     * plain deferred `BEGIN` that doesn't take SQLite's write lock until the
     * first actual write) forces the lock at the START of the transaction —
     * before the read — so a second connection's own BEGIN IMMEDIATE has to
     * wait (via Database::connect()'s busy_timeout) until the first
     * transaction commits. That guarantees the second caller's SELECT can
     * only ever see state that already includes the first caller's write,
     * never a stale pre-write snapshot — the actual condition that causes
     * the lost update.
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
     * call in the same "unit story" session can hand the adapter the right
     * room-numbering offset. 0 for a session with no floor plan yet.
     */
    public function roomCount(string $sessionId): int
    {
        $floorPlan = $this->findFloorPlan($sessionId);
        return $floorPlan === null ? 0 : count($floorPlan['rooms']);
    }

    /**
     * Appends the rooms from a newly-adapted capture onto the session's
     * existing FloorPlan (if any), rather than overwriting it — this is
     * what makes a multi-room "unit story" session (PHASES.md Phase 2)
     * possible: each guided RoomPlan capture covers one room, and this is
     * the seam that stitches them into one coherent result. photos/notes
     * are preserved from the existing record; captured_at advances to this
     * capture's timestamp so it always reflects the most recent room added.
     */
    public function appendCapture(string $sessionId, array $newFloorPlan): array
    {
        return $this->withWriteLock(function () use ($sessionId, $newFloorPlan) {
            $existing = $this->findFloorPlan($sessionId);
            if ($existing === null) {
                $this->saveFloorPlan($sessionId, $newFloorPlan);
                return $newFloorPlan;
            }

            $merged = $existing;
            $merged['rooms'] = array_merge($existing['rooms'], $newFloorPlan['rooms']);
            $merged['captured_at'] = $newFloorPlan['captured_at'];
            $merged['capture_provider'] = $newFloorPlan['capture_provider'];

            $this->saveFloorPlan($sessionId, $merged);
            return $merged;
        });
    }

    /**
     * Photos/notes attach to the same unit package as a hard requirement
     * (PHASES.md Phase 2: "not a separate side-channel") — both live inside
     * the same floor_plans row/contract_json as rooms, never a side table
     * joined only by convention.
     */
    public function appendPhoto(string $sessionId, array $photo): array
    {
        return $this->appendToContractArray($sessionId, 'photos', $photo);
    }

    public function appendNote(string $sessionId, array $note): array
    {
        return $this->appendToContractArray($sessionId, 'notes', $note);
    }

    /**
     * Found by deliberately probing the adjacent case to the "before any
     * capture" 409 above: nothing checked that an attached photo/note's
     * `room_id`, when the caller bothers to send one, actually names a room
     * that exists on this session. A typo'd or stale room_id was silently
     * stored and returned as if it were a real association — quietly wrong
     * data, not a crash, exactly the class of bug hard constraint #2's
     * honesty standard is about (same shape as the degenerate-geometry fix
     * in RoomPlanSimulatorAdapter).
     */
    private function appendToContractArray(string $sessionId, string $field, array $item): array
    {
        return $this->withWriteLock(function () use ($sessionId, $field, $item) {
            $floorPlan = $this->findFloorPlan($sessionId);
            if ($floorPlan === null) {
                throw new \RuntimeException(
                    "Cannot attach a $field to scan session $sessionId before it has a captured FloorPlan."
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

    // Sentinel stored in idempotency_keys.response_json while a claimed key's
    // capture is still being processed — never valid JSON a real FloorPlan
    // would produce, so findIdempotentResponse() can tell "someone else is
    // mid-request" apart from "no one has ever recorded a real result yet."
    private const IDEMPOTENCY_PENDING_MARKER = '__pending__';

    /**
     * Enterprise reliability hardening: a mobile client on spotty on-site
     * wifi (flagged as a real, unsolved concern in
     * ios-app/Sources/Networking/ScanServiceClient.swift's header comment)
     * may retry a capture upload after never seeing the response to the
     * first attempt. Without this, a retried POST .../capture would append
     * the same room twice. Returns the previously-stored FloorPlan response
     * if this exact (session, key) pair was already fully processed. Returns
     * null both when this key has never been seen AND when it's currently
     * claimed-but-still-processing (see claimIdempotencyKey) — either way,
     * the caller has no finished result to hand back yet.
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
     * Adjacent case to findIdempotentResponse() above: that method answers
     * "is there a finished result to replay," but says nothing about whether
     * THIS request is even the same request the key was originally claimed
     * for. A key reused with a genuinely different body (client bug, or two
     * distinct room captures accidentally sharing a key) must not silently
     * replay the first response — that's real capture data quietly going
     * missing, worse than the double-append this feature exists to prevent.
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
     * (session, key) pair. Found by deliberately probing the adjacent case
     * to the retry logic above: two requests carrying the SAME
     * Idempotency-Key that arrive close enough together can both pass
     * findIdempotentResponse() (both see null) before either one has stored
     * anything, and both would then append a room — the exact double-append
     * this feature exists to prevent, just reached by a race instead of a
     * naive retry. The UNIQUE constraint on (scan_session_id,
     * idempotency_key) is what actually makes this safe under real
     * concurrency (PHP-FPM/production, not the single-threaded dev server):
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
     * Fixed-window rate limiter (enterprise hardening — see the "Known
     * limits" note in scan-service/README.md about unlimited session
     * creation). `$bucket` is the caller's own composite key (typically IP +
     * route); counting and enforcement are separate on purpose so a caller
     * can check-then-record atomically enough for a single-process PHP dev
     * server without needing a separate cache/lock service.
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
    }

    public static function uuid(): string
    {
        $data = random_bytes(16);
        $data[6] = chr((ord($data[6]) & 0x0f) | 0x40);
        $data[8] = chr((ord($data[8]) & 0x3f) | 0x80);
        return vsprintf('%s%s-%s-%s-%s-%s%s%s', str_split(bin2hex($data), 4));
    }
}
