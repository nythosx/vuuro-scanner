<?php

declare(strict_types=1);

namespace VuuroScan\Export;

final class ExportLanguage
{
    public const EN = 'en';
    public const NL = 'nl';
    public const SUPPORTED = [self::EN, self::NL];
    public const DEFAULT = self::EN;

    public const NL_TEXT = [
        'Indicative measurements - NEN2580-inspired, not certified. No rights can be derived from this plan.' => 'Indicatieve maten - geïnspireerd op NEN2580, niet gecertificeerd. Aan deze plattegrond kunnen geen rechten worden ontleend.',
        'Indicative measurements — NEN2580-inspired, not certified. No rights can be derived from this plan.' => 'Indicatieve maten — geïnspireerd op NEN2580, niet gecertificeerd. Aan deze plattegrond kunnen geen rechten worden ontleend.',
        'Vuuro Scan - indicative per-room floor plan sheet' => 'Vuuro Scan - indicatieve plattegrond per ruimte',
        'Vuuro Scan — indicative per-room floor plan sheet' => 'Vuuro Scan — indicatieve plattegrond per ruimte',
        'Room shapes accurate individually; rooms are not laid out relative to each other.' => 'De vorm per ruimte klopt; de ruimtes staan niet op hun onderlinge plek.',
        'Total indicative area: %s across %d room(s)' => 'Totale indicatieve oppervlakte: %s over %d ruimte(s)',
        'Vuuro Scan - fused floor plan (rooms captured together in one visit)' => 'Vuuro Scan - samengevoegde plattegrond (ruimtes in één bezoek gescand)',
        'Vuuro Scan — fused floor plan (rooms captured together)' => 'Vuuro Scan — samengevoegde plattegrond (ruimtes samen gescand)',
        'Room positions relative to each other, not independently verified beyond this capture (see docs/proposals/multi-room-fusion.md).' => 'Onderlinge positie van de ruimtes, niet los gecontroleerd buiten deze scan.',
        'Room positions relative to each other, not independently verified beyond this capture.' => 'Onderlinge positie van de ruimtes, niet los gecontroleerd buiten deze scan.',
        'WARNING: rooms below overlap in captured position - verify against the real layout before use.' => 'LET OP: ruimtes hieronder overlappen in de gescande positie - controleer de echte indeling voor gebruik.',
        'WARNING: rooms below overlap in captured position — verify against the real layout before use.' => 'LET OP: ruimtes hieronder overlappen in de gescande positie — controleer de echte indeling voor gebruik.',
        'WARNING: some rooms below overlap in captured position (%s) - verify against the real layout before use.' => 'LET OP: sommige ruimtes hieronder overlappen in de gescande positie (%s) - controleer de echte indeling voor gebruik.',
        'WARNING: some rooms below overlap in captured position - verify against the real layout before use.' => 'LET OP: sommige ruimtes hieronder overlappen in de gescande positie - controleer de echte indeling voor gebruik.',
        'Notes:' => 'Notities:',
        'tags:' => 'labels:',
        'Whole unit' => 'Hele woning',
        'Room summary:' => 'Overzicht ruimtes:',
        '%s floor area' => '%s vloeroppervlak',
        '%s perimeter' => '%s omtrek',
        '%s height' => '%s hoogte',
        '%s indicative' => '%s indicatief',
        '%s confidence' => 'betrouwbaarheid %s',
        '%s - %s perimeter - %s confidence' => '%s - %s omtrek - betrouwbaarheid %s',
        '%s — %s perimeter — %s confidence' => '%s — %s omtrek — betrouwbaarheid %s',
        'Floor plan' => 'Plattegrond',
        'Total floor area %s (indicative)' => 'Totale vloeroppervlakte %s (indicatief)',
        'door' => 'deur',
        'window' => 'raam',
        'other opening' => 'andere opening',
        'walk path' => 'looproute',
        'detected object' => 'gedetecteerd object',
        'high' => 'hoog',
        'medium' => 'gemiddeld',
        'low' => 'laag',
        'Floor not set' => 'Verdieping niet ingevuld',
        '%s (separate scan %d)' => '%s (aparte scan %d)',
        'Floor plan drawing' => 'Plattegrond',
        'Floor plan drawing - %s' => 'Plattegrond - %s',
        'Vuuro Scan - Floor Plan' => 'Vuuro Scan - Plattegrond',
        'Property: %s   Unit: %s   Organisation: %s' => 'Pand: %s   Eenheid: %s   Organisatie: %s',
        'Purpose: %s   Captured: %s' => 'Doel: %s   Gescand: %s',
        'Indicative, NEN2580-inspired measurements. This is NOT a certified survey.' => 'Indicatieve maten, geïnspireerd op NEN2580. Dit is GEEN gecertificeerde meting.',
        'Measurement basis: %s' => 'Meetgrondslag: %s',
        '%d room(s)  -  total indicative area %s' => '%d ruimte(s)  -  totale indicatieve oppervlakte %s',
        '+ %d more room(s), each on its own page' => '+ nog %d ruimte(s), elk op een eigen pagina',
        '+ %d more room(s), listed in the metrics table' => '+ nog %d ruimte(s), in de tabel met maten',
        'Floor: %s' => 'Verdieping: %s',
        '   Size: %s x %s' => '   Afmetingen: %s x %s',
        'Area: %s   Perimeter: %s%s' => 'Oppervlakte: %s   Omtrek: %s%s',
        'Height: %s   Indicative capacity: %s' => 'Hoogte: %s   Indicatieve inhoud: %s',
        'Height: %s' => 'Hoogte: %s',
        'Openings: %s' => 'Openingen: %s',
        'Detected objects: %s' => 'Gedetecteerde objecten: %s',
        'Confidence: %s' => 'Betrouwbaarheid: %s',
        'Missing item: %s' => 'Ontbrekend item: %s',
        'Note: %s' => 'Notitie: %s',
        'Photos: %d (on the photo pages)' => "Foto's: %d (op de fotopagina's)",
        'Listing' => 'Aanbod',
        'Move-in inspection' => 'Ingangsinspectie',
        'Move-out inspection' => 'Eindinspectie',
        'Renovation' => 'Renovatie',
        'Other' => 'Overig',
        '%s  -  Page %d of %d' => '%s  -  Pagina %d van %d',
        'Floor Plan Metrics' => 'Maten van de plattegrond',
        'Vuuro Scan - Floor Plan Metrics' => 'Vuuro Scan - Maten van de plattegrond',
        'Rooms' => 'Ruimtes',
        '%-20s %12s   %14s   confidence: %s' => '%-20s %12s   %14s   betrouwbaarheid: %s',
        '             %s height   %s indicative capacity' => '             %s hoogte   %s indicatieve inhoud',
        '             %s height' => '             %s hoogte',
        '             walk path: %d point(s) recorded' => '             looproute: %d punt(en) vastgelegd',
        '             detected objects: %s' => '             gedetecteerde objecten: %s',
        'missing item: ' => 'ontbrekend item: ',
        'note: ' => 'notitie: ',
        'Whole-unit notes' => 'Notities voor de hele woning',
        'Photos attached: %d   Notes attached: %d' => "Foto's: %d   Notities: %d",
        'Changes since check-in' => 'Wijzigingen sinds de ingangsinspectie',
        'Changes since the earlier scan' => 'Wijzigingen sinds de vorige scan',
        'Compared with the %s scan of %s. Indicative: both scans are mobile LiDAR captures, so areas can differ slightly without any real change. A room counts as changed above %s or %s%%.' => 'Vergeleken met de scan (%s) van %s. Indicatief: beide scans zijn mobiele LiDAR-scans, dus oppervlaktes kunnen iets verschillen zonder echte wijziging. Een ruimte telt als gewijzigd boven %s of %s%%.',
        'Rooms with a different indicative area' => 'Ruimtes met een andere indicatieve oppervlakte',
        'Rooms in this scan only' => 'Ruimtes die alleen in deze scan staan',
        'Rooms from the earlier scan not matched' => 'Ruimtes uit de vorige scan zonder match',
        'Not matched means no room with the same name and floor was found. It does not mean the room was removed.' => 'Zonder match betekent dat er geen ruimte met dezelfde naam en verdieping is gevonden. Het betekent niet dat de ruimte is verwijderd.',
        'Objects from the earlier scan not found again' => 'Objecten uit de vorige scan die niet zijn teruggevonden',
        'Notes and photos in this scan' => "Notities en foto's in deze scan",
        "Photos: %d (%d tagged damage), on the photo pages" => "Foto's: %d (%d met label schade), op de fotopagina's",
        'No room changed above the threshold, and nothing else was added or missing.' => 'Geen ruimte is meer veranderd dan de drempel, en er is niets toegevoegd of verdwenen.',
        'Room %d' => 'Ruimte %d',
        'Living room' => 'Woonkamer',
        'Bedroom' => 'Slaapkamer',
        'Bathroom' => 'Badkamer',
        'Kitchen' => 'Keuken',
        'Dining room' => 'Eetkamer',
        'Hallway' => 'Hal',
        'Office' => 'Kantoor',
        'Garage' => 'Garage',
        'Laundry room' => 'Wasruimte',
        'Storage room' => 'Berging',
        'Balcony' => 'Balkon',
        'Basement' => 'Kelder',
        'Attic' => 'Zolder',
        'Walk-in closet' => 'Inloopkast',
        'Guest room' => 'Logeerkamer',
        'Damage' => 'Schade',
        'Wear and tear' => 'Slijtage',
        'Missing item' => 'Ontbrekend item',
        'Safety issue' => 'Veiligheidsprobleem',
        'Pre-existing condition' => 'Al aanwezig',
        'Maintenance needed' => 'Onderhoud nodig',
        'Confirmed present' => 'Aanwezig bevestigd',
        'Sink' => 'Wastafel',
        'Toilet' => 'Toilet',
        'Bathtub' => 'Bad',
        'Stove' => 'Fornuis',
        'Oven' => 'Oven',
        'Dishwasher' => 'Vaatwasser',
        'Fridge' => 'Koelkast',
        'Washer/Dryer' => 'Wasmachine/droger',
        'Fireplace' => 'Open haard',
        'Stairs' => 'Trap',
        'Bed' => 'Bed',
        'Sofa' => 'Bank',
        'Chair' => 'Stoel',
        'Table' => 'Tafel',
        'Desk' => 'Bureau',
        'TV' => 'Tv',
        'Storage' => 'Opbergkast',
    ];

    private const NL_MONTHS = ['jan', 'feb', 'mrt', 'apr', 'mei', 'jun', 'jul', 'aug', 'sep', 'okt', 'nov', 'dec'];
    private const NL_OPENINGS = [
        'door' => ['deur', 'deuren'],
        'window' => ['raam', 'ramen'],
        'opening' => ['opening', 'openingen'],
    ];

    private static string $current = self::DEFAULT;

    public static function isSupported(mixed $lang): bool
    {
        return is_string($lang) && in_array($lang, self::SUPPORTED, true);
    }

    public static function current(): string
    {
        return self::$current;
    }

    public static function run(string $lang, callable $render): mixed
    {
        if (!self::isSupported($lang)) {
            throw new \InvalidArgumentException("Unsupported export language '{$lang}'.");
        }
        $previous = self::$current;
        self::$current = $lang;
        try {
            return $render();
        } finally {
            self::$current = $previous;
        }
    }

    public static function t(string $text, mixed ...$args): string
    {
        $template = self::$current === self::NL ? (self::NL_TEXT[$text] ?? $text) : $text;
        return $args === [] ? $template : sprintf($template, ...$args);
    }

    public static function number(float $value, int $decimals): string
    {
        return self::$current === self::NL
            ? number_format($value, $decimals, ',', '.')
            : number_format($value, $decimals, '.', '');
    }

    public static function date(string $timestamp): string
    {
        $date = date_create($timestamp);
        if ($date === false) {
            return $timestamp;
        }
        if (self::$current === self::NL) {
            return $date->format('j') . ' ' . self::NL_MONTHS[(int) $date->format('n') - 1] . ' ' . $date->format('Y');
        }
        return $date->format('M j, Y');
    }

    public static function openingCount(string $category, int $count): string
    {
        if (self::$current === self::NL) {
            $names = self::NL_OPENINGS[$category] ?? [$category, $category];
            return $count . ' ' . ($count === 1 ? $names[0] : $names[1]);
        }
        return "{$count} {$category}" . ($count === 1 ? '' : 's');
    }

    public static function objectName(string $category): string
    {
        if (self::$current !== self::NL || !FurnitureCatalog::isKnown($category)) {
            return $category;
        }
        return mb_strtolower(FurnitureCatalog::labelFor($category), 'UTF-8');
    }
}
