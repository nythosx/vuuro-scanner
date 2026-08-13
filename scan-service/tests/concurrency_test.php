<?php

declare(strict_types=1);

/**
 * Real multi-process concurrency test for ScanSessionRepository's write
 * locking, kept separate from tests/repository_test.php's fast in-memory
 * suite because it's genuinely slower (~2s) and needs an on-disk SQLite
 * file, not :memory: (an in-memory DB isn't shared across connections, so
 * it can't be used to prove real cross-connection lock contention).
 *
 * Found by deliberately probing the adjacent case to the idempotency-claim
 * race fix: that fix only protects two requests sharing the SAME
 * Idempotency-Key. appendCapture()/appendToContractArray() (photos, notes)
 * are a plain read-then-modify-then-write against one session's floor_plans
 * row — findFloorPlan() (SELECT), merge in PHP, saveFloorPlan() (INSERT ...
 * ON CONFLICT DO UPDATE) — with no locking at all before the fix in this
 * file's git history. Two concurrent writers to the SAME session (e.g. two
 * captures with no shared Idempotency-Key, or a capture racing a photo
 * attach) could both read the same pre-write state and the second write
 * would silently clobber the first: not a double-append, a genuine data
 * loss with no error on either side. Reproduced before the fix with a
 * single-connection simulated interleaving (findFloorPlan() called twice
 * before either saveFloorPlan()) — confirmed the room was lost. That trick
 * only proves the BUG, though; it can't prove a FIX built on transaction
 * locking, since a single connection can't hold two overlapping
 * transactions with itself. Proving the fix needs real, separate
 * connections under real lock contention, which is what this file does:
 * spawns a genuinely separate PHP process (worker A) that holds
 * ScanSessionRepository's write lock open for 2 seconds while this process
 * (as "worker B") calls the real, fixed appendCapture() against the same
 * on-disk file at the same time.
 *
 * net/verify_*.php can't do this either — the PHP built-in dev server
 * (`php -S`) those scripts talk to is single-threaded and processes one
 * HTTP request at a time, so two real concurrent HTTP requests never
 * actually overlap at the server. This file bypasses HTTP entirely and
 * exercises the repository layer directly under real OS-level concurrency,
 * which is the only way to observe this class of bug or verify its fix in
 * this environment. Still fully independent of the tests it's proving:
 * PHP's SQLite locking semantics (BEGIN IMMEDIATE + busy_timeout) are a
 * standard, external, well-documented mechanism, not an assumption borrowed
 * from ScanSessionRepository's own implementation.
 *
 * Usage: php tests/concurrency_test.php
 */

require __DIR__ . '/../src/autoload.php';

use VuuroScan\ScanSessionRepository;
use VuuroScan\Storage\Database;

$failures = [];
$checks = 0;

function c_check(string $label, bool $pass, string $detail = ''): void
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

$dbFile = sys_get_temp_dir() . '/vuuro_scan_concurrency_test_' . bin2hex(random_bytes(6)) . '.sqlite';
@unlink($dbFile);

$db = Database::connect($dbFile);
$repo = new ScanSessionRepository($db);
$session = $repo->create('prop-concurrency-test', 'unit-concurrency-test', 'org-concurrency-test', 'listing', false, false);
$sessionId = $session['id'];

echo "== Two concurrent capture()s on the same session must not lose a room ==\n";

// Worker A: a genuinely separate PHP process. Opens its own connection to
// the same on-disk file, acquires ScanSessionRepository's write lock
// (BEGIN IMMEDIATE, via reflection into the private withWriteLock() method
// — deliberately reusing the real implementation rather than hand-rolling
// "BEGIN IMMEDIATE" again here, so this test tracks the actual mechanism,
// not a copy of it that could silently drift out of sync), sleeps for 2s
// while still holding it, then appends room-A and commits.
$workerScript = <<<'PHP'
<?php
declare(strict_types=1);
require $argv[1] . '/../src/autoload.php';
use VuuroScan\ScanSessionRepository;
use VuuroScan\Storage\Database;

$dbFile = $argv[2];
$sessionId = $argv[3];

$db = Database::connect($dbFile);
$repo = new ScanSessionRepository($db);

$lock = new ReflectionMethod(ScanSessionRepository::class, 'withWriteLock');
$lock->setAccessible(true);
$lock->invoke($repo, function () use ($repo, $sessionId) {
    $repo->findFloorPlan($sessionId); // real read, inside the real lock
    sleep(2); // hold the lock open, simulating a slow request
    $repo->saveFloorPlan($sessionId, [
        'scan_session_id' => $sessionId, 'capture_provider' => 'test',
        'captured_at' => '2026-08-13T00:00:00Z', 'measurement_basis' => 'indicative_nen2580_inspired',
        'purpose' => 'listing', 'rooms' => [['room_id' => 'room-A', 'label' => 'Room A']],
        'photos' => [], 'notes' => [],
    ]);
});
PHP;

$workerFile = sys_get_temp_dir() . '/vuuro_scan_race_worker_' . bin2hex(random_bytes(6)) . '.php';
file_put_contents($workerFile, $workerScript);

$srcRoot = __DIR__;
$descriptors = [1 => ['pipe', 'w'], 2 => ['pipe', 'w']];
$process = proc_open(
    [PHP_BINARY, $workerFile, $srcRoot, $dbFile, $sessionId],
    $descriptors,
    $pipes
);
c_check('worker process (simulating a slow concurrent capture) launched', $process !== false);

if ($process !== false) {
    fclose($pipes[1]);
    fclose($pipes[2]);

    // Give worker A time to actually acquire the lock before this process
    // (acting as "worker B") tries its own real, fixed appendCapture() call.
    usleep(500_000);

    $start = microtime(true);
    $result = $repo->appendCapture($sessionId, [
        'scan_session_id' => $sessionId, 'capture_provider' => 'test',
        'captured_at' => '2026-08-13T00:00:01Z', 'measurement_basis' => 'indicative_nen2580_inspired',
        'purpose' => 'listing', 'rooms' => [['room_id' => 'room-B', 'label' => 'Room B']],
        'photos' => [], 'notes' => [],
    ]);
    $elapsed = microtime(true) - $start;

    proc_close($process);
    @unlink($workerFile);

    // The actual mechanism check: if the lock is real, this call could not
    // have returned in well under a second, because worker A was still
    // holding the write lock for roughly another 1.5s at the moment this
    // call started. A call that returns near-instantly means the two writes
    // were NOT actually serialized — the exact pre-fix condition.
    c_check(
        "this process's own appendCapture() call blocked waiting for worker A's lock (took {$elapsed}s, expected > 1s)",
        $elapsed > 1.0,
        'a fast return here means the two writes were not serialized, which is the exact condition that caused the lost-update bug'
    );

    c_check("this process's own appendCapture() returned both rooms in its own result, not just room-B", count($result['rooms']) === 2, 'got ' . count($result['rooms']) . ' room(s) in the return value');

    $final = $repo->findFloorPlan($sessionId);
    $finalRoomIds = array_column($final['rooms'], 'room_id');
    sort($finalRoomIds);
    c_check(
        'both room-A (from the slow worker) and room-B (from this process) survive in the final stored FloorPlan',
        $finalRoomIds === ['room-A', 'room-B'],
        'got: ' . implode(', ', $finalRoomIds)
    );
}

@unlink($dbFile);

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
