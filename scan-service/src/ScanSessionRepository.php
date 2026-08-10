<?php

declare(strict_types=1);

namespace VuuroScan;

use PDO;

final class ScanSessionRepository
{
    public function __construct(private PDO $db)
    {
    }

    public function create(
        string $propertyId,
        string $unitId,
        string $organisationId,
        string $purpose,
        bool $occupied,
        bool $consentObtained
    ): array {
        $id = self::uuid();
        $accessToken = self::uuid();
        $createdAt = gmdate('c');
        $stmt = $this->db->prepare(
            'INSERT INTO scan_sessions (id, property_id, unit_id, organisation_id, purpose, created_at, status, access_token, occupied, consent_obtained)
             VALUES (:id, :property_id, :unit_id, :organisation_id, :purpose, :created_at, :status, :access_token, :occupied, :consent_obtained)'
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
        ]);

        return $this->find($id);
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

    private function appendToContractArray(string $sessionId, string $field, array $item): array
    {
        $floorPlan = $this->findFloorPlan($sessionId);
        if ($floorPlan === null) {
            throw new \RuntimeException(
                "Cannot attach a $field to scan session $sessionId before it has a captured FloorPlan."
            );
        }

        $floorPlan[$field][] = $item;
        $this->saveFloorPlan($sessionId, $floorPlan);
        return $floorPlan;
    }

    public static function uuid(): string
    {
        $data = random_bytes(16);
        $data[6] = chr((ord($data[6]) & 0x0f) | 0x40);
        $data[8] = chr((ord($data[8]) & 0x3f) | 0x80);
        return vsprintf('%s%s-%s-%s-%s-%s%s%s', str_split(bin2hex($data), 4));
    }
}
