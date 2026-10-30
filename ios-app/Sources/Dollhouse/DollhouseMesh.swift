import Foundation
import simd

struct DollhouseVertex: Equatable {
    let position: SIMD3<Float>
    let normal: SIMD3<Float>
    var uv: SIMD2<Float>? = nil
}

struct DollhouseMaterial: Equatable {
    let name: String
    let color: SIMD4<Float>
    let roughness: Float
    let metalness: Float
    var imageData: Data? = nil

    static let exteriorWall = DollhouseMaterial(name: "exteriorWall", color: SIMD4(0.58, 0.56, 0.53, 1.0), roughness: 0.9, metalness: 0.0)
    static let interiorWall = DollhouseMaterial(name: "interiorWall", color: SIMD4(0.84, 0.83, 0.80, 1.0), roughness: 0.9, metalness: 0.0)
    static let door = DollhouseMaterial(name: "door", color: SIMD4(1.0, 0.51, 0.07, 1.0), roughness: 0.7, metalness: 0.0)
    static let window = DollhouseMaterial(name: "window", color: SIMD4(0.18, 0.76, 1.0, 1.0), roughness: 0.4, metalness: 0.0)
    static let otherOpening = DollhouseMaterial(name: "otherOpening", color: SIMD4(0.55, 0.55, 0.56, 1.0), roughness: 0.8, metalness: 0.0)
    static let openEdge = DollhouseMaterial(name: "openEdge", color: SIMD4(0.54, 0.54, 0.54, 1.0), roughness: 1.0, metalness: 0.0)
    static let overlapWarning = DollhouseMaterial(name: "overlapWarning", color: SIMD4(0.84, 0.27, 0.24, 1.0), roughness: 0.9, metalness: 0.0)
    static let ceiling = DollhouseMaterial(name: "ceiling", color: SIMD4(0.93, 0.92, 0.90, 1.0), roughness: 0.95, metalness: 0.0)

    static func floor(named name: String, color: SIMD4<Float>) -> DollhouseMaterial {
        DollhouseMaterial(name: name, color: color, roughness: 0.95, metalness: 0.0)
    }

    static func furniture(named name: String, color: SIMD4<Float>) -> DollhouseMaterial {
        DollhouseMaterial(name: name, color: color, roughness: 0.85, metalness: 0.0)
    }
}

enum DollhouseLayer: String, CaseIterable, Identifiable {
    case wallsAndFloors
    case doors
    case windows
    case openings
    case furniture
    case ceiling
    case roomLabels
    case hotspotMarkers

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wallsAndFloors: return "3D floor plan"
        case .doors: return "Doors"
        case .windows: return "Windows"
        case .openings: return "Openings"
        case .furniture: return "Furniture"
        case .ceiling: return "Ceiling"
        case .roomLabels: return "Room labels"
        case .hotspotMarkers: return "Hotspot markers"
        }
    }
}

struct DollhouseHotspot: Equatable, Identifiable {
    let id: String
    let roomId: String
    let position: SIMD3<Float>
}

struct DollhouseNodePath: Equatable, Hashable {
    let components: [String]

    init(_ components: [String]) {
        self.components = components
    }

    var identifier: String { components.joined(separator: "/") }

    func appending(_ component: String) -> DollhouseNodePath {
        DollhouseNodePath(components + [component])
    }
}

struct DollhouseMesh: Equatable {
    let vertices: [DollhouseVertex]
    let indices: [UInt32]
    let material: DollhouseMaterial
    let layer: DollhouseLayer
    let path: DollhouseNodePath

    var triangleCount: Int { indices.count / 3 }
    var isEmpty: Bool { vertices.isEmpty || indices.isEmpty }
}

struct DollhouseFloorSection: Equatable, Identifiable {
    let id: String
    let title: String
    let roomIds: [String]
    let originOffset: SIMD3<Float>
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>
}

struct DollhouseRoomLabel: Equatable, Identifiable {
    let id: String
    let text: String
    let floorCenter: SIMD3<Float>
    let labelHeightM: Float
    let areaM2: Float
}

struct DollhouseScene {
    let meshes: [DollhouseMesh]
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>
    let roomCount: Int
    let floorSections: [DollhouseFloorSection]
    let usedEstimatedHeight: Bool
    let id: UUID = UUID()
    var headingDeg: Double? = nil
    var defaultYaw: Float = .pi / 4
    var degenerateRoomCount: Int = 0
    var hotspots: [DollhouseHotspot] = []
    var roomLabels: [DollhouseRoomLabel] = []

    var boundsCenter: SIMD3<Float> { (boundsMin + boundsMax) * 0.5 }
    var boundsSize: SIMD3<Float> { boundsMax - boundsMin }
    var totalTriangles: Int { meshes.reduce(0) { $0 + $1.triangleCount } }
    var isEmpty: Bool { meshes.isEmpty }
}
