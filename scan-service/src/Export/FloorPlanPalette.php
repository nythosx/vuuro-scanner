<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class FloorPlanPalette
{
    public const EXTERIOR_WALL_THICKNESS_M = 0.30;
    public const INTERIOR_WALL_THICKNESS_M = 0.12;

    public const ROOM_BUCKET_FILL = [
        'garage' => '#cccccc',
        'wet' => '#d4e2f0',
        'circ' => '#fcc778',
        'bed' => '#ecc486',
        'living' => '#f2d8b0',
        'neutral' => '#ffffff',
    ];

    public const ROOM_TYPE_BUCKET = [
        'living_room' => 'living',
        'dining_room' => 'living',
        'office' => 'living',
        'bedroom' => 'bed',
        'guest_room' => 'bed',
        'kitchen' => 'wet',
        'bathroom' => 'wet',
        'laundry_room' => 'wet',
        'hallway' => 'circ',
        'garage' => 'garage',
        'storage_room' => 'garage',
        'basement' => 'garage',
        'attic' => 'garage',
        'walk_in_closet' => 'neutral',
        'balcony' => 'neutral',
    ];

    public const FIXTURE_FILL = '#b4b4b4';
    public const FIXTURE_LINE = '#5c5c5c';
    public const FIXTURE_LIGHT = '#d4d4d4';
    public const HEARTH_FILL = '#5c5c5c';
    public const BED_FRAME_FILL = '#8f9bb3';

    public static function roomFillFor(?string $roomType): ?string
    {
        if ($roomType === null) {
            return null;
        }
        $normalized = strtolower(str_replace([' ', '-'], '_', $roomType));
        $bucket = self::ROOM_TYPE_BUCKET[$normalized] ?? null;
        return $bucket !== null ? self::ROOM_BUCKET_FILL[$bucket] : null;
    }

    public static function hexToRgb(string $hex): array
    {
        $hex = ltrim($hex, '#');
        return [
            hexdec(substr($hex, 0, 2)),
            hexdec(substr($hex, 2, 2)),
            hexdec(substr($hex, 4, 2)),
        ];
    }
}
