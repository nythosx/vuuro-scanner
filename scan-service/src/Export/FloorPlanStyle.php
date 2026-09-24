<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class FloorPlanStyle
{
    public const ORIENTATIONS = ['as_captured', 'longest_horizontal'];
    public const ROOM_FILLS = ['default', 'white'];

    public function __construct(
        public readonly bool $isFunda,
        public readonly bool $showWalkPath,
        public readonly ?array $furnitureCategories,
        public readonly string $orientation,
        public readonly array $doorColor,
        public readonly bool $showCompass,
        public readonly bool $showMetrics,
        public readonly bool $showNotes,
        public readonly bool $showRoomTypeLegend,
        public readonly string $roomFill,
        public readonly ?string $titleLine,
    ) {
    }

    public function shouldDrawFurniture(string $category): bool
    {
        if ($this->furnitureCategories === null) {
            return true;
        }
        if ($this->furnitureCategories === []) {
            return false;
        }
        return in_array(FurnitureCatalog::normalize($category), $this->furnitureCategories, true);
    }

    public function resolvedTitle(array $floorPlan): ?string
    {
        if ($this->titleLine !== null) {
            return $this->titleLine;
        }
        if (!$this->isFunda) {
            return null;
        }
        $propertyId = (string) ($floorPlan['property_id'] ?? '');
        $unitId = (string) ($floorPlan['unit_id'] ?? '');
        $rooms = $floorPlan['rooms'] ?? [];
        $floors = [];
        foreach ($rooms as $room) {
            $floor = $room['floor'] ?? null;
            if (is_string($floor) && trim($floor) !== '') {
                $floors[] = trim($floor);
            }
        }
        $floors = array_values(array_unique($floors));
        $floorName = count($floors) === 1 ? $floors[0] : null;
        $parts = [];
        if ($propertyId !== '') $parts[] = $propertyId;
        if ($unitId !== '') $parts[] = $unitId;
        if ($floorName !== null) $parts[] = $floorName;
        return $parts === [] ? null : implode(" \u{00B7} ", $parts);
    }

    public static function from(
        string $style = 'default',
        ?string $walkPath = null,
        ?string $furniture = null,
        ?string $orientation = null,
        ?string $roomFill = null,
        ?string $title = null,
    ): self {
        $isFunda = $style === 'funda';

        $showWalkPath = $walkPath !== null
            ? ($walkPath === '1' || $walkPath === 'true')
            : !$isFunda;

        $furnitureCategories = null;
        if ($furniture !== null) {
            if ($furniture === 'all') {
                $furnitureCategories = null;
            } elseif ($furniture === 'none') {
                $furnitureCategories = [];
            } elseif ($furniture === 'fixtures') {
                $furnitureCategories = FurnitureCatalog::FIXTURES;
            } else {
                $list = array_values(array_filter(array_map('trim', explode(',', $furniture))));
                $furnitureCategories = array_values(array_unique(array_map(
                    [FurnitureCatalog::class, 'normalize'],
                    $list
                )));
            }
        } elseif ($isFunda) {
            $furnitureCategories = FurnitureCatalog::FIXTURES;
        }

        $orientationMode = $orientation ?? ($isFunda ? 'longest_horizontal' : 'as_captured');
        $roomFillMode = $roomFill ?? ($isFunda ? 'white' : 'default');

        return new self(
            isFunda: $isFunda,
            showWalkPath: $showWalkPath,
            furnitureCategories: $furnitureCategories,
            orientation: $orientationMode,
            doorColor: $isFunda ? [0, 0, 0] : [255, 130, 18],
            showCompass: true,
            showMetrics: !$isFunda,
            showNotes: !$isFunda,
            showRoomTypeLegend: !$isFunda,
            roomFill: $roomFillMode,
            titleLine: $title,
        );
    }
}
