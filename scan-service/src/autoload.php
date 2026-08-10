<?php

declare(strict_types=1);

// Zero-dependency PSR-4-ish autoloader. No composer install required to run
// this service — deliberate, since the only thing this repo needs from
// composer right now is autoloading, and adding the dependency just to get
// that is not worth the extra install step for a Phase 1 proof.
spl_autoload_register(function (string $class): void {
    $prefix = 'VuuroScan\\';
    if (!str_starts_with($class, $prefix)) {
        return;
    }
    $relative = substr($class, strlen($prefix));
    $path = __DIR__ . '/' . str_replace('\\', '/', $relative) . '.php';
    if (is_file($path)) {
        require $path;
    }
});
