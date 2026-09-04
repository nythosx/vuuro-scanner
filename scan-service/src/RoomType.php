<?php

declare(strict_types=1);

namespace VuuroScan;

final class RoomType
{
    public const VALUES = ['living_room', 'bedroom', 'bathroom', 'kitchen', 'dining_room'];
    public const GUESS_SOURCES = ['roomplan_section', 'object_heuristic'];
    public const CONFIRMED_VALUES = [...self::VALUES, 'other'];
    public const LABELS = [
        'living_room' => 'Living room',
        'bedroom' => 'Bedroom',
        'bathroom' => 'Bathroom',
        'kitchen' => 'Kitchen',
        'dining_room' => 'Dining room',
    ];
}
