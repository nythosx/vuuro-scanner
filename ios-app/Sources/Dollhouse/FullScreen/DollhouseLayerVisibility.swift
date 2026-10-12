import Foundation

struct DollhouseLayerVisibility: Equatable {
    var wallsAndFloors: Bool = true
    var doors: Bool = true
    var windows: Bool = true
    var openings: Bool = true
    var furniture: Bool = true
    var ceiling: Bool = false
    var roomLabels: Bool = true
    var hotspotMarkers: Bool = true

    func isVisible(_ layer: DollhouseLayer) -> Bool {
        switch layer {
        case .wallsAndFloors: return wallsAndFloors
        case .doors: return doors
        case .windows: return windows
        case .openings: return openings
        case .furniture: return furniture
        case .ceiling: return ceiling
        case .roomLabels: return roomLabels
        case .hotspotMarkers: return hotspotMarkers
        }
    }

    subscript(layer: DollhouseLayer) -> Bool {
        get { isVisible(layer) }
        set {
            switch layer {
            case .wallsAndFloors: wallsAndFloors = newValue
            case .doors: doors = newValue
            case .windows: windows = newValue
            case .openings: openings = newValue
            case .furniture: furniture = newValue
            case .ceiling: ceiling = newValue
            case .roomLabels: roomLabels = newValue
            case .hotspotMarkers: hotspotMarkers = newValue
            }
        }
    }
}
