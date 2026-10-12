<?php

declare(strict_types=1);

namespace VuuroScan\Storage;

use PDO;

final class DatabaseBackup
{
    public const MIN_INTERVAL_SECONDS = 24 * 60 * 60;
    public const MAX_KEPT = 14;

    public static function create(PDO $db, string $dbPath, bool $force = false): ?string
    {
        if (!is_file($dbPath)) {
            return null;
        }
        $backupDir = dirname($dbPath) . '/backups';
        if (!is_dir($backupDir) && !mkdir($backupDir, 0750, true) && !is_dir($backupDir)) {
            error_log("DatabaseBackup: could not create backup directory $backupDir");
            return null;
        }

        $lockHandle = fopen($backupDir . '/.backup.lock', 'c');
        if ($lockHandle === false) {
            return null;
        }
        if (!flock($lockHandle, $force ? LOCK_EX : LOCK_EX | LOCK_NB)) {
            fclose($lockHandle);
            return null;
        }

        try {
            $lastBackupMarker = $backupDir . '/.last_backup_at';
            $lastBackupAt = is_file($lastBackupMarker) ? (int) filemtime($lastBackupMarker) : 0;
            if (!$force && $lastBackupAt !== 0 && time() - $lastBackupAt < self::MIN_INTERVAL_SECONDS) {
                return null;
            }

            $backupPath = $backupDir . '/' . gmdate('Ymd\THis\Z') . '.sqlite';
            if (!is_file($backupPath)) {
                try {
                    $db->exec('VACUUM INTO ' . $db->quote($backupPath));
                } catch (\PDOException $e) {
                    error_log('DatabaseBackup: VACUUM INTO failed: ' . $e->getMessage());
                    return null;
                }
            }
            touch($lastBackupMarker);

            $all = glob($backupDir . '/*.sqlite') ?: [];
            sort($all);
            $excess = count($all) - self::MAX_KEPT;
            for ($i = 0; $i < $excess; $i++) {
                unlink($all[$i]);
            }
            return $backupPath;
        } finally {
            flock($lockHandle, LOCK_UN);
            fclose($lockHandle);
        }
    }
}
