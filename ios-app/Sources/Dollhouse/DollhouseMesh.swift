import Foundation
import simd

struct DollhouseVertex: Equatable {
    let position: SIMD3<Float>
    let normal: SIMD3<Float>
}

struct DollhouseMaterial: Equatable {
    let name: String
    let color: SIMD4<Float>
    let roughness: Float
    let metalness: Float

    static let exteriorWall = DollhouseMaterial(name: "exteriorWall", color: SIMD4(0.0, 0.0, 0.0, 1.0), roughness: 0.9, metalness: 0.0)
    static let interiorWall = DollhouseMaterial(name: "interiorWall", color: SIMD4(0.11, 0.11, 0.12, 1.0), roughness: 0.9, metalness: 0.0)
    static let door = DollhouseMaterial(name: "door", color: SIMD4(1.0, 0.51, 0.07, 1.0), roughness: 0.7, metalness: 0.0)
    static let window = DollhouseMaterial(name: "window", color: SIMD4(0.18, 0.76, 1.0, 1.0), roughness: 0.4, metalness: 0.0)
    static let otherOpening = DollhouseMaterial(name: "otherOpening", color: SIMD4(0.55, 0.55, 0.56, 1.0), roughness: 0.8, metalness: 0.0)
    static let openEdge = DollhouseMaterial(name: "openEdge", color: SIMD4(0.54, 0.54, 0.54, 1.0), roughness: 1.0, metalness: 0.0)
    static let overlapWarning = DollhouseMaterial(name: "overlapWarning", color: SIMD4(0.84, 0.27, 0.24, 1.0), roughness: 0.9, metalness: 0.0)

    static func floor(named name: String, color: SIMD4<Float>) -> DollhouseMaterial {
        DollhouseMaterial(name: name, color: color, roughness: 0.95, metalness: 0.0)
    }

    static func furniture(named name: String, color: SIMD4<Float>) -> DollhouseMaterial {
        DollhouseMaterial(name: name, color: color, roughness: 0.85, metalness: 0.0)
    }
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

struct DollhouseScene {
    let meshes: [DollhouseMesh]
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>
    let roomCount: Int
    let floorSections: [DollhouseFloorSection]
    let usedEstimatedHeight: Bool
    let id: UUID = UUID()
    var headingDeg: Double? = nil
    var degenerateRoomCount: Int = 0

    var boundsCenter: SIMD3<Float> { (boundsMin + boundsMax) * 0.5 }
    var boundsSize: SIMD3<Float> { boundsMax - boundsMin }
    var totalTriangles: Int { meshes.reduce(0) { $0 + $1.triangleCount } }
    var isEmpty: Bool { meshes.isEmpty }
}
