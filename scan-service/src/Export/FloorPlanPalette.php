<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class FloorPlanPalette
{
    public const EXTERIOR_WALL_THICKNESS_M = 0.30;
    public const INTERIOR_WALL_THICKNESS_M = 0.12;

    // Vuuro brand palette (see ios-app/Sources/Design/VuuroDesign.swift) —
    // exports should look like they came from the same product as the app.
    public const BRAND_PRIMARY = '#ff8212';
    public const BRAND_ACCENT_LIME = '#afdf25';
    public const BRAND_ACCENT_CYAN = '#2ec3ff';
    public const BRAND_INK = '#272729';
    public const BRAND_INK_MUTED = '#87878a';
    public const BRAND_SURFACE = '#f2f1ec';
    public const BRAND_SURFACE_MUTED = '#f9f9fb';
    public const BRAND_BORDER = '#ececee';
    public const BRAND_DANGER = '#d6453e';
    public const BRAND_WARNING_TEXT = '#b45a0d';
    public const BRAND_GOOD_TEXT = '#5b7a0a';

    public const ROOM_BUCKET_FILL = [
        'garage' => '#e7e4dd',
        'wet' => '#dff3ff',
        'circ' => '#eef6d2',
        'bed' => '#f3d9a6',
        'living' => '#fbe3c7',
        'neutral' => '#fbfbfa',
    ];

    public const ROOM_BUCKET_ACCENT = [
        'garage' => '#9a958a',
        'wet' => '#2ec3ff',
        'circ' => '#afdf25',
        'bed' => '#e0a940',
        'living' => '#ff8212',
        'neutral' => '#c8c8c8',
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

    public static function roomAccentFor(?string $roomType): ?string
    {
        if ($roomType === null) {
            return null;
        }
        $normalized = strtolower(str_replace([' ', '-'], '_', $roomType));
        $bucket = self::ROOM_TYPE_BUCKET[$normalized] ?? null;
        return $bucket !== null ? self::ROOM_BUCKET_ACCENT[$bucket] : null;
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
