<?php

declare(strict_types=1);

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
    $repo->findFloorPlan($sessionId);
    sleep(2);
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

echo "\n== A capture that fails under real lock contention must not strand its Idempotency-Key ==\n";

$idempotencyDbFile = sys_get_temp_dir() . '/vuuro_scan_idempotency_concurrency_test_' . bin2hex(random_bytes(6)) . '.sqlite';
@unlink($idempotencyDbFile);
$idempotencyDb = Database::connect($idempotencyDbFile);
$idempotencyRepo = new ScanSessionRepository($idempotencyDb);
$idempotencySessionId = $idempotencyRepo->create('prop-concurrency-idem', 'unit-concurrency-idem', 'org-concurrency-idem', 'listing', false, false)['id'];

$lockHoldingWorkerScript = <<<'PHP'
<?php
declare(strict_types=1);
require $argv[1] . '/../src/autoload.php';
use VuuroScan\ScanSessionRepository;
use VuuroScan\Storage\Database;

$db = Database::connect($argv[2]);
$repo = new ScanSessionRepository($db);
$lock = new ReflectionMethod(ScanSessionRepository::class, 'withWriteLock');
$lock->setAccessible(true);
$lock->invoke($repo, function () {
    sleep(6);
});
PHP;
$lockHoldingWorkerFile = sys_get_temp_dir() . '/vuuro_scan_idempotency_lock_worker_' . bin2hex(random_bytes(6)) . '.php';
file_put_contents($lockHoldingWorkerFile, $lockHoldingWorkerScript);

$idempotencyKey = 'concurrency-test-key';
$claimed = $idempotencyRepo->claimIdempotencyKey($idempotencySessionId, $idempotencyKey, 'fp');
c_check('idempotency key claimed before contention starts', $claimed);

$lockProcess = proc_open([PHP_BINARY, $lockHoldingWorkerFile, __DIR__, $idempotencyDbFile], $descriptors, $lockPipes);
if ($lockProcess !== false) {
    fclose($lockPipes[1]);
    fclose($lockPipes[2]);
    usleep(300_000);

    $threwUnderContention = false;
    try {
        $idempotencyRepo->appendCapture($idempotencySessionId, [
            'scan_session_id' => $idempotencySessionId, 'capture_provider' => 'test',
            'captured_at' => '2026-08-18T00:00:00Z', 'measurement_basis' => 'indicative_nen2580_inspired',
            'purpose' => 'listing', 'rooms' => [['room_id' => 'room-idem', 'label' => 'Room 1']],
            'photos' => [], 'notes' => [],
        ]);
    } catch (\Throwable $e) {
        $threwUnderContention = true;
        $idempotencyRepo->releaseIdempotencyKey($idempotencySessionId, $idempotencyKey);
    }
    c_check('appendCapture() actually threw under real lock contention (proves this test exercises the real failure, not a no-op)', $threwUnderContention);

    proc_close($lockProcess);
    @unlink($lockHoldingWorkerFile);

    $reclaimable = $idempotencyRepo->claimIdempotencyKey($idempotencySessionId, $idempotencyKey, 'fp-retry');
    c_check(
        'after the release, the SAME Idempotency-Key can be claimed again on retry, not stuck forever',
        $reclaimable
    );
}

@unlink($idempotencyDbFile);

echo "\n== Two concurrent deleteNote() calls for the SAME note_id must not both succeed or corrupt the note list ==\n";

$deleteDbFile = sys_get_temp_dir() . '/vuuro_scan_delete_race_test_' . bin2hex(random_bytes(6)) . '.sqlite';
@unlink($deleteDbFile);
$deleteDb = Database::connect($deleteDbFile);
$deleteRepo = new ScanSessionRepository($deleteDb);
$deleteSessionId = $deleteRepo->create('prop-concurrency-delete', 'unit-concurrency-delete', 'org-concurrency-delete', 'listing', false, false)['id'];
$deleteRepo->appendCapture($deleteSessionId, [
    'scan_session_id' => $deleteSessionId, 'capture_provider' => 'test',
    'captured_at' => '2026-09-11T00:00:00Z', 'measurement_basis' => 'indicative_nen2580_inspired',
    'purpose' => 'listing', 'rooms' => [['room_id' => 'room-del', 'label' => 'Room 1']],
    'photos' => [], 'notes' => [],
]);
$noteAfterAdd = $deleteRepo->appendNote($deleteSessionId, [
    'note_id' => 'note-race-1', 'text' => 'racing this one', 'room_id' => 'room-del', 'created_at' => '2026-09-11T00:00:01Z',
]);
c_check('note to be raced on was actually added first', count($noteAfterAdd['notes']) === 1);

$deleteWorkerScript = <<<'PHP'
<?php
declare(strict_types=1);
require $argv[1] . '/../src/autoload.php';
use VuuroScan\ScanSessionRepository;
use VuuroScan\Storage\Database;

$db = Database::connect($argv[2]);
$repo = new ScanSessionRepository($db);
try {
    $repo->deleteNote($argv[3], $argv[4]);
    echo "OK\n";
} catch (\InvalidArgumentException $e) {
    echo "NOT_FOUND\n";
}
PHP;
$deleteWorkerFile = sys_get_temp_dir() . '/vuuro_scan_delete_race_worker_' . bin2hex(random_bytes(6)) . '.php';
file_put_contents($deleteWorkerFile, $deleteWorkerScript);

$deleteDescriptors = [1 => ['pipe', 'w'], 2 => ['pipe', 'w']];
$deleteProcess = proc_open(
    [PHP_BINARY, $deleteWorkerFile, __DIR__, $deleteDbFile, $deleteSessionId, 'note-race-1'],
    $deleteDescriptors,
    $deletePipes
);
c_check('racing worker process launched', $deleteProcess !== false);

if ($deleteProcess !== false) {
    fclose($deletePipes[2]);

    $mainOutcome = 'OK';
    try {
        $deleteRepo->deleteNote($deleteSessionId, 'note-race-1');
    } catch (\InvalidArgumentException $e) {
        $mainOutcome = 'NOT_FOUND';
    }

    $workerOutcome = trim((string) stream_get_contents($deletePipes[1]));
    fclose($deletePipes[1]);
    proc_close($deleteProcess);
    @unlink($deleteWorkerFile);

    $outcomes = [$mainOutcome, $workerOutcome];
    sort($outcomes);
    c_check(
        'exactly one side deleted the note and the other found it already gone — never both OK, never both NOT_FOUND',
        $outcomes === ['NOT_FOUND', 'OK'],
        'got main=' . $mainOutcome . ' worker=' . $workerOutcome
    );

    $finalFloorPlan = $deleteRepo->findFloorPlan($deleteSessionId);
    c_check(
        'the note is gone exactly once — no duplicate removal side effect, no note resurrected',
        count($finalFloorPlan['notes']) === 0,
        'got ' . count($finalFloorPlan['notes']) . ' note(s) remaining'
    );
}

@unlink($deleteDbFile);

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