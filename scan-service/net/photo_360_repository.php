<?php

declare(strict_types=1);

final class Photo360Repository
{
    private PDO $pdo;

    public function __construct(PDO $pdo)
    {
        $this->pdo = $pdo;
    }

    public function insert(
        string $sessionId,
        string $roomId,
        string $url,
        float $positionX,
        float $positionZ,
        float $headingDeg,
        string $capturedAt,
        string $idempotencyKey,
        float $zoom = 1.0,
        float $pitchDeg = 0.0,
        string $standId = '',
        string $cameraTransformJson = '',
        string $intrinsicsJson = '',
        string $depthUrl = '',
        int $depthWidth = 0,
        int $depthHeight = 0,
        string $depthIntrinsicsJson = ''
    ): array {
        $stmt = $this->pdo->prepare(
            'INSERT INTO photo_360 (session_id, room_id, url, position_x, position_z, heading_deg, zoom, pitch_deg, stand_id, camera_transform, intrinsics, depth_url, depth_width, depth_height, depth_intrinsics, captured_at, idempotency_key)
             VALUES (:session_id, :room_id, :url, :position_x, :position_z, :heading_deg, :zoom, :pitch_deg, :stand_id, :camera_transform, :intrinsics, :depth_url, :depth_width, :depth_height, :depth_intrinsics, :captured_at, :idempotency_key)'
        );
        $stmt->execute([
            ':session_id' => $sessionId,
            ':room_id' => $roomId,
            ':url' => $url,
            ':position_x' => $positionX,
            ':position_z' => $positionZ,
            ':heading_deg' => $headingDeg,
            ':zoom' => $zoom,
            ':pitch_deg' => $pitchDeg,
            ':stand_id' => $standId,
            ':camera_transform' => $cameraTransformJson,
            ':intrinsics' => $intrinsicsJson,
            ':depth_url' => $depthUrl,
            ':depth_width' => $depthWidth,
            ':depth_height' => $depthHeight,
            ':depth_intrinsics' => $depthIntrinsicsJson,
            ':captured_at' => $capturedAt,
            ':idempotency_key' => $idempotencyKey,
        ]);
        return $this->findById((int) $this->pdo->lastInsertId());
    }

    public function findById(int $id): array
    {
        $stmt = $this->pdo->prepare('SELECT * FROM photo_360 WHERE id = :id LIMIT 1');
        $stmt->execute([':id' => $id]);
        $row = $stmt->fetch(PDO::FETCH_ASSOC);
        return $row === false ? [] : $row;
    }

    public function findByIdempotencyKey(string $sessionId, string $idempotencyKey): ?array
    {
        $stmt = $this->pdo->prepare(
            'SELECT * FROM photo_360 WHERE session_id = :session_id AND idempotency_key = :idempotency_key LIMIT 1'
        );
        $stmt->execute([':session_id' => $sessionId, ':idempotency_key' => $idempotencyKey]);
        $row = $stmt->fetch(PDO::FETCH_ASSOC);
        return $row === false ? null : $row;
    }

    public function listBySession(string $sessionId): array
    {
        $stmt = $this->pdo->prepare('SELECT * FROM photo_360 WHERE session_id = :session_id ORDER BY id ASC');
        $stmt->execute([':session_id' => $sessionId]);
        return $stmt->fetchAll(PDO::FETCH_ASSOC);
    }

    public function listByRoom(string $sessionId, string $roomId): array
    {
        $stmt = $this->pdo->prepare(
            'SELECT * FROM photo_360 WHERE session_id = :session_id AND room_id = :room_id ORDER BY id ASC'
        );
        $stmt->execute([':session_id' => $sessionId, ':room_id' => $roomId]);
        return $stmt->fetchAll(PDO::FETCH_ASSOC);
    }

    public function countByRoom(string $sessionId, string $roomId): int
    {
        $stmt = $this->pdo->prepare(
            'SELECT COUNT(*) FROM photo_360 WHERE session_id = :session_id AND room_id = :room_id'
        );
        $stmt->execute([':session_id' => $sessionId, ':room_id' => $roomId]);
        return (int) $stmt->fetchColumn();
    }

    public function deleteBySession(string $sessionId): int
    {
        $stmt = $this->pdo->prepare('DELETE FROM photo_360 WHERE session_id = :session_id');
        $stmt->execute([':session_id' => $sessionId]);
        return $stmt->rowCount();
    }

    public function serialize(array $row): array
    {
        return [
            'photo_id' => (string) $row['id'],
            'room_id' => (string) $row['room_id'],
            'url' => (string) $row['url'],
            'position_m' => [(float) $row['position_x'], (float) $row['position_z']],
            'heading_deg' => (float) $row['heading_deg'],
            'zoom' => (float) ($row['zoom'] ?? 1.0),
            'pitch_deg' => (float) ($row['pitch_deg'] ?? 0.0),
            'stand_id' => (string) ($row['stand_id'] ?? ''),
            'has_depth' => ($row['depth_url'] ?? '') !== '',
            'camera_transform' => self::decodedJsonList($row['camera_transform'] ?? '', 16),
            'intrinsics' => self::decodedJsonList($row['intrinsics'] ?? '', 4),
            'depth_width' => ($row['depth_url'] ?? '') !== '' && (int) ($row['depth_width'] ?? 0) > 0 ? (int) $row['depth_width'] : null,
            'depth_height' => ($row['depth_url'] ?? '') !== '' && (int) ($row['depth_height'] ?? 0) > 0 ? (int) $row['depth_height'] : null,
            'depth_intrinsics' => ($row['depth_url'] ?? '') !== '' ? self::decodedJsonList($row['depth_intrinsics'] ?? '', 4) : null,
            'captured_at' => (string) $row['captured_at'],
        ];
    }

    public function serializeList(array $rows): array
    {
        return array_map([$this, 'serialize'], $rows);
    }

    public function serializedForSession(string $sessionId): array
    {
        return $this->serializeList($this->listBySession($sessionId));
    }

    private static function decodedJsonList(string $json, int $expectedLength): ?array
    {
        if ($json === '') {
            return null;
        }
        $decoded = json_decode($json, true);
        if (!is_array($decoded) || !array_is_list($decoded) || count($decoded) !== $expectedLength) {
            return null;
        }
        return $decoded;
    }
}
