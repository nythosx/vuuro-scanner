<?php

declare(strict_types=1);

require __DIR__ . '/../src/autoload.php';

use VuuroScan\ServiceSettings;
use VuuroScan\Storage\Database;

$failures = [];
$checks = 0;

function ss_check(string $label, bool $pass, string $detail = ''): void
{
    global $failures, $checks;
    $checks++;
    if ($pass) {
        echo "  [PASS] $label\n";
    } else {
        $failures[] = "$label — $detail";
        echo "  [FAIL] $label — $detail\n";
    }
}

function ss_rejects(callable $fn): bool
{
    try {
        $fn();
    } catch (\InvalidArgumentException) {
        return true;
    }
    return false;
}

foreach (ServiceSettings::PURPOSES as $purpose) {
    putenv('SCAN_SERVICE_RETENTION_DAYS_' . strtoupper($purpose));
}

$settings = new ServiceSettings(Database::connect(':memory:'));

echo "== Defaults ==\n";
$defaults = $settings->all();
ss_check('every purpose starts switched off', array_filter(array_column($defaults['retention'], 'enabled')) === []);
ss_check('the suggested days are pre-filled', $defaults['retention']['check_out']['days'] === 30 && $defaults['retention']['check_in']['days'] === 365);
ss_check('nothing is purged by default', $settings->activeRetentionDays() === []);
ss_check('tenant deletion requests are on with 7 days by default', $settings->tenantDeletionEnabled() && $settings->tenantGraceDays() === 7);
ss_check('no env value means switched off with the default source', $defaults['retention']['check_out']['enabled'] === false && $defaults['retention']['check_out']['source'] === 'default' && $defaults['retention']['check_out']['server_config_days'] === null);

echo "\n== Empty env values from .env.example keep retention off ==\n";
foreach (ServiceSettings::PURPOSES as $purpose) {
    putenv('SCAN_SERVICE_RETENTION_DAYS_' . strtoupper($purpose) . '=');
}
$emptyEnv = $settings->all()['retention'];
ss_check('an empty env value does not switch any purpose on', array_filter(array_column($emptyEnv, 'enabled')) === [] && $settings->activeRetentionDays() === []);
ss_check('an empty env value reports the default source', array_unique(array_column($emptyEnv, 'source')) === ['default']);
ss_check('the admin page still suggests the usual days', array_combine(ServiceSettings::PURPOSES, array_column($emptyEnv, 'days')) === ServiceSettings::SUGGESTED_RETENTION_DAYS);
foreach (ServiceSettings::PURPOSES as $purpose) {
    putenv('SCAN_SERVICE_RETENTION_DAYS_' . strtoupper($purpose));
}

echo "\n== Server config still counts until an admin changes it ==\n";
putenv('SCAN_SERVICE_RETENTION_DAYS_CHECK_OUT=45');
ss_check('an env value switches that purpose on', $settings->activeRetentionDays() === ['check_out' => 45]);
ss_check('and says where it came from', $settings->all()['retention']['check_out']['source'] === 'env');
$settings->update(['retention' => ['check_out' => ['enabled' => false]]]);
ss_check('an admin switch overrides the env value', $settings->activeRetentionDays() === []);
putenv('SCAN_SERVICE_RETENTION_DAYS_CHECK_OUT');

echo "\n== Changing settings ==\n";
$updated = $settings->update(['retention' => ['listing' => ['enabled' => true, 'days' => 120]], 'tenant_deletion' => ['enabled' => false, 'grace_days' => 14]]);
ss_check('a purpose can be switched on with its own days', $settings->activeRetentionDays() === ['listing' => 120]);
ss_check('other purposes keep their state', $updated['retention']['renovation']['enabled'] === false);
ss_check('tenant deletion can be switched off with other grace days', !$settings->tenantDeletionEnabled() && $settings->tenantGraceDays() === 14);
$settings->update(['retention' => ['listing' => ['days' => 60]]]);
ss_check('a partial change keeps the on/off state', $settings->activeRetentionDays() === ['listing' => 60]);

ss_check('an unknown purpose is refused', ss_rejects(fn () => $settings->update(['retention' => ['holiday' => ['enabled' => true]]])));
ss_check('zero days is refused', ss_rejects(fn () => $settings->update(['retention' => ['listing' => ['days' => 0]]])));
ss_check('days as text is refused', ss_rejects(fn () => $settings->update(['retention' => ['listing' => ['days' => '30']]])));
ss_check('enabled as a number is refused', ss_rejects(fn () => $settings->update(['retention' => ['listing' => ['enabled' => 1]]])));
ss_check('grace days over 90 are refused', ss_rejects(fn () => $settings->update(['tenant_deletion' => ['grace_days' => 91]])));
ss_check('an empty change is refused', ss_rejects(fn () => $settings->update([])));
ss_check('a refused change leaves the settings untouched', $settings->activeRetentionDays() === ['listing' => 60] && $settings->tenantGraceDays() === 14);

echo "\n== Going back to the server config ==\n";
putenv('SCAN_SERVICE_RETENTION_DAYS_LISTING=200');
ss_check('the admin choice still wins while it is saved', $settings->activeRetentionDays() === ['listing' => 60]);
ss_check('the server value is shown next to it', $settings->all()['retention']['listing']['server_config_days'] === 200);
$settings->update(['retention' => ['listing' => null]]);
ss_check('resetting a purpose hands it back to the server config', $settings->activeRetentionDays() === ['listing' => 200] && $settings->all()['retention']['listing']['source'] === 'env');
putenv('SCAN_SERVICE_RETENTION_DAYS_LISTING');

echo "\n== Every change is logged ==\n";
$settings->update(['tenant_deletion' => ['enabled' => true]], 'admin key abcd1234 from 10.0.0.5');
$history = $settings->history();
ss_check('each saved change is written to the settings log', count($history) === 5, (string) count($history));
ss_check('the newest entry names who changed it', $history[0]['actor'] === 'admin key abcd1234 from 10.0.0.5');
ss_check('the log keeps the value before and after', $history[0]['before']['tenant_deletion']['enabled'] === false && $history[0]['after']['tenant_deletion']['enabled'] === true);
ss_check('refused changes are not logged', count(array_filter($history, static fn (array $h) => $h['before'] === $h['after'] && $h['actor'] === 'admin')) === 0);
echo "
== Default plan per purpose ==
";
ss_check('every purpose starts on Listing plan', array_unique(array_values($settings->all()['plan_style'])) === ['listing']);
$settings->update(['plan_style' => ['check_in' => 'full', 'check_out' => 'full']]);
ss_check('check-in and check-out can default to Full report', $settings->planStyleFor('check_in') === 'full' && $settings->planStyleFor('check_out') === 'full' && $settings->planStyleFor('listing') === 'listing');
ss_check('an unknown plan is refused', ss_rejects(fn () => $settings->update(['plan_style' => ['listing' => 'fancy']])));
ss_check('the plan change is in the log', $settings->history()[0]['after']['plan_style']['check_in'] === 'full' && $settings->history()[0]['before']['plan_style']['check_in'] === 'listing');
ss_check('the limits are sent so the admin page does not hard-code them', $settings->all()['limits']['tenant_grace_days'] === ['min' => 1, 'max' => 90]);

echo "\n== Check-in vs check-out thresholds ==\n";
ss_check('a room counts as changed from 0.5 m2 or 5% by default', $settings->areaChangeThresholds() === [0.5, 5.0], json_encode($settings->areaChangeThresholds()));
$settings->update(['comparison' => ['area_change_m2' => 1]]);
ss_check('the m2 threshold can be changed on its own', $settings->areaChangeThresholds() === [1.0, 5.0], json_encode($settings->areaChangeThresholds()));
$settings->update(['comparison' => ['area_change_percent' => 7.5]]);
ss_check('the percent threshold keeps the m2 value', $settings->areaChangeThresholds() === [1.0, 7.5], json_encode($settings->areaChangeThresholds()));
ss_check('a zero m2 threshold is refused', ss_rejects(fn () => $settings->update(['comparison' => ['area_change_m2' => 0]])));
ss_check('a percent over 100 is refused', ss_rejects(fn () => $settings->update(['comparison' => ['area_change_percent' => 101]])));
ss_check('a threshold as text is refused', ss_rejects(fn () => $settings->update(['comparison' => ['area_change_m2' => '1']])));
ss_check('comparison must be an object', ss_rejects(fn () => $settings->update(['comparison' => 2])));
ss_check('a refused threshold leaves the old values', $settings->areaChangeThresholds() === [1.0, 7.5]);
ss_check('the threshold change is in the log', $settings->history()[0]['after']['comparison']['area_change_percent'] == 7.5 && $settings->history()[0]['before']['comparison']['area_change_percent'] == 5);
ss_check('exports default to English', $settings->exportLanguage() === 'en');
$settings->update(['export_language' => 'nl']);
ss_check('the default export language can be Dutch', $settings->exportLanguage() === 'nl');
ss_check('an unknown export language is refused', ss_rejects(fn () => $settings->update(['export_language' => 'de'])));
ss_check('a refused language keeps Dutch', $settings->exportLanguage() === 'nl');
ss_check('the language change is in the log', $settings->history()[0]['after']['export_language'] === 'nl' && $settings->history()[0]['before']['export_language'] === 'en');
ss_check('the threshold limits are sent to the admin page', $settings->all()['limits']['area_change_m2'] === ['min' => 0.05, 'max' => 20.0] && $settings->all()['limits']['area_change_percent'] === ['min' => 0.5, 'max' => 100.0]);

echo "\n" . count($failures) . " failure(s) out of $checks check(s).\n";
if ($failures !== []) {
    fwrite(STDERR, "\nTEST VERDICT: RED\n");
    foreach ($failures as $f) {
        fwrite(STDERR, " - $f\n");
    }
    exit(1);
}

echo "\nTEST VERDICT: GREEN\n";
exit(0);
