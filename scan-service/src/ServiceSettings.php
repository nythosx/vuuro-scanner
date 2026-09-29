<?php

declare(strict_types=1);

namespace VuuroScan;

use PDO;

final class ServiceSettings
{
    public const PURPOSES = ['listing', 'check_in', 'check_out', 'renovation', 'other'];
    public const SUGGESTED_RETENTION_DAYS = [
        'listing' => 90,
        'check_in' => 365,
        'check_out' => 30,
        'renovation' => 365,
        'other' => 180,
    ];
    public const MIN_RETENTION_DAYS = 1;
    public const MAX_RETENTION_DAYS = 3650;
    public const DEFAULT_TENANT_GRACE_DAYS = 7;
    public const MIN_TENANT_GRACE_DAYS = 1;
    public const MAX_TENANT_GRACE_DAYS = 90;

    public function __construct(private PDO $db)
    {
    }

    public function all(): array
    {
        $stored = $this->stored();
        $retention = [];
        foreach (self::PURPOSES as $purpose) {
            $env = self::envDays($purpose);
            $saved = $stored['retention.' . $purpose] ?? null;
            if (is_array($saved)) {
                $retention[$purpose] = [
                    'enabled' => (bool) ($saved['enabled'] ?? false),
                    'days' => (int) ($saved['days'] ?? self::SUGGESTED_RETENTION_DAYS[$purpose]),
                    'source' => 'admin',
                    'server_config_days' => $env,
                ];
                continue;
            }
            $retention[$purpose] = [
                'enabled' => $env !== null,
                'days' => $env ?? self::SUGGESTED_RETENTION_DAYS[$purpose],
                'source' => $env !== null ? 'env' : 'default',
                'server_config_days' => $env,
            ];
        }
        $tenant = $stored['tenant_deletion'] ?? null;
        return [
            'limits' => [
                'retention_days' => ['min' => self::MIN_RETENTION_DAYS, 'max' => self::MAX_RETENTION_DAYS],
                'tenant_grace_days' => ['min' => self::MIN_TENANT_GRACE_DAYS, 'max' => self::MAX_TENANT_GRACE_DAYS],
            ],
            'retention' => $retention,
            'tenant_deletion' => [
                'enabled' => is_array($tenant) ? (bool) ($tenant['enabled'] ?? true) : true,
                'grace_days' => is_array($tenant) ? (int) ($tenant['grace_days'] ?? self::DEFAULT_TENANT_GRACE_DAYS) : self::DEFAULT_TENANT_GRACE_DAYS,
            ],
        ];
    }

    public function activeRetentionDays(): array
    {
        $active = [];
        foreach ($this->all()['retention'] as $purpose => $rule) {
            if ($rule['enabled']) {
                $active[$purpose] = $rule['days'];
            }
        }
        return $active;
    }

    public function tenantDeletionEnabled(): bool
    {
        return $this->all()['tenant_deletion']['enabled'];
    }

    public function tenantGraceDays(): int
    {
        return $this->all()['tenant_deletion']['grace_days'];
    }

    public function update(array $changes, string $actor = 'admin'): array
    {
        $writes = [];
        $resets = [];
        $current = $this->all();
        if (array_key_exists('retention', $changes)) {
            if (!is_array($changes['retention'])) {
                throw new \InvalidArgumentException("'retention' must be an object keyed by purpose.");
            }
            foreach ($changes['retention'] as $purpose => $rule) {
                if (!in_array($purpose, self::PURPOSES, true)) {
                    throw new \InvalidArgumentException("Unknown purpose '{$purpose}'. Use one of: " . implode(', ', self::PURPOSES) . '.');
                }
                if ($rule === null) {
                    $resets[] = 'retention.' . $purpose;
                    continue;
                }
                if (!is_array($rule)) {
                    throw new \InvalidArgumentException("retention.{$purpose} must be an object with 'enabled' and/or 'days'.");
                }
                $enabled = $rule['enabled'] ?? $current['retention'][$purpose]['enabled'];
                $days = $rule['days'] ?? $current['retention'][$purpose]['days'];
                if (!is_bool($enabled)) {
                    throw new \InvalidArgumentException("retention.{$purpose}.enabled must be true or false.");
                }
                if (!is_int($days) || $days < self::MIN_RETENTION_DAYS || $days > self::MAX_RETENTION_DAYS) {
                    throw new \InvalidArgumentException("retention.{$purpose}.days must be a whole number from " . self::MIN_RETENTION_DAYS . ' to ' . self::MAX_RETENTION_DAYS . '.');
                }
                $writes['retention.' . $purpose] = ['enabled' => $enabled, 'days' => $days];
            }
        }
        if (array_key_exists('tenant_deletion', $changes)) {
            $rule = $changes['tenant_deletion'];
            if (!is_array($rule)) {
                throw new \InvalidArgumentException("'tenant_deletion' must be an object with 'enabled' and/or 'grace_days'.");
            }
            $enabled = $rule['enabled'] ?? $current['tenant_deletion']['enabled'];
            $graceDays = $rule['grace_days'] ?? $current['tenant_deletion']['grace_days'];
            if (!is_bool($enabled)) {
                throw new \InvalidArgumentException('tenant_deletion.enabled must be true or false.');
            }
            if (!is_int($graceDays) || $graceDays < self::MIN_TENANT_GRACE_DAYS || $graceDays > self::MAX_TENANT_GRACE_DAYS) {
                throw new \InvalidArgumentException('tenant_deletion.grace_days must be a whole number from ' . self::MIN_TENANT_GRACE_DAYS . ' to ' . self::MAX_TENANT_GRACE_DAYS . '.');
            }
            $writes['tenant_deletion'] = ['enabled' => $enabled, 'grace_days' => $graceDays];
        }
        if ($writes === [] && $resets === []) {
            throw new \InvalidArgumentException("Nothing to change. Send 'retention' and/or 'tenant_deletion'.");
        }

        $stmt = $this->db->prepare(
            'INSERT INTO app_settings (setting_key, value_json, updated_at) VALUES (:key, :value, :updated)
             ON CONFLICT(setting_key) DO UPDATE SET value_json = excluded.value_json, updated_at = excluded.updated_at'
        );
        $reset = $this->db->prepare('DELETE FROM app_settings WHERE setting_key = :key');
        $this->db->beginTransaction();
        try {
            foreach ($writes as $key => $value) {
                $stmt->execute(['key' => $key, 'value' => json_encode($value, JSON_THROW_ON_ERROR), 'updated' => gmdate('c')]);
            }
            foreach ($resets as $key) {
                $reset->execute(['key' => $key]);
            }
            $after = $this->all();
            $log = $this->db->prepare(
                'INSERT INTO app_settings_log (changed_at, actor, before_json, after_json) VALUES (:changed, :actor, :before, :after)'
            );
            $log->execute([
                'changed' => gmdate('c'),
                'actor' => $actor,
                'before' => json_encode(self::policyOnly($current), JSON_THROW_ON_ERROR),
                'after' => json_encode(self::policyOnly($after), JSON_THROW_ON_ERROR),
            ]);
            $this->db->commit();
        } catch (\Throwable $e) {
            $this->db->rollBack();
            throw $e;
        }
        return $after;
    }

    public function history(int $limit = 20): array
    {
        $stmt = $this->db->prepare('SELECT changed_at, actor, before_json, after_json FROM app_settings_log ORDER BY id DESC LIMIT :limit');
        $stmt->bindValue(':limit', $limit, PDO::PARAM_INT);
        $stmt->execute();
        return array_map(static fn (array $row) => [
            'changed_at' => $row['changed_at'],
            'actor' => $row['actor'],
            'before' => json_decode((string) $row['before_json'], true),
            'after' => json_decode((string) $row['after_json'], true),
        ], $stmt->fetchAll(PDO::FETCH_ASSOC));
    }

    private static function policyOnly(array $settings): array
    {
        $policy = ['retention' => [], 'tenant_deletion' => $settings['tenant_deletion']];
        foreach ($settings['retention'] as $purpose => $rule) {
            $policy['retention'][$purpose] = ['enabled' => $rule['enabled'], 'days' => $rule['days'], 'source' => $rule['source']];
        }
        return $policy;
    }

    private function stored(): array
    {
        $rows = $this->db->query('SELECT setting_key, value_json FROM app_settings')->fetchAll(PDO::FETCH_ASSOC);
        $out = [];
        foreach ($rows as $row) {
            $decoded = json_decode((string) $row['value_json'], true);
            if (is_array($decoded)) {
                $out[$row['setting_key']] = $decoded;
            }
        }
        return $out;
    }

    private static function envDays(string $purpose): ?int
    {
        $raw = getenv('SCAN_SERVICE_RETENTION_DAYS_' . strtoupper($purpose));
        if ($raw === false || !ctype_digit(trim((string) $raw)) || (int) $raw < 1) {
            return null;
        }
        return (int) $raw;
    }
}
