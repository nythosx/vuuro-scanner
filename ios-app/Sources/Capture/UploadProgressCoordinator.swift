import Foundation
import RoomPlan
import simd

enum VuuroUploadRowState: Equatable {
    case pending
    case uploading
    case done(areaM2: Double?)
    case failed
}

struct VuuroUploadRow: Identifiable, Equatable {
    let id: String
    let name: String
    var state: VuuroUploadRowState
}

@MainActor
final class UploadProgressCoordinator: ObservableObject {
    @Published private(set) var rows: [VuuroUploadRow] = []
    @Published private(set) var currentIndex: Int = 0

    var totalRooms: Int { rows.count }

    var completedRooms: Int {
        rows.reduce(0) { partial, row in
            if case .done = row.state { return partial + 1 }
            return partial
        }
    }

    var overallProgress: Double {
        guard !rows.isEmpty else { return 0 }
        return Double(completedRooms) / Double(rows.count)
    }

    func begin(roomLabels: [String]) {
        rows = roomLabels.enumerated().map { index, label in
            VuuroUploadRow(id: "room-\(index)", name: label, state: .pending)
        }
        currentIndex = 0
    }

    func markUploading(index: Int) {
        guard rows.indices.contains(index) else { return }
        rows[index].state = .uploading
        currentIndex = index
    }

    func markDone(index: Int, areaM2: Double?) {
        guard rows.indices.contains(index) else { return }
        rows[index].state = .done(areaM2: areaM2)
    }

    func markFailed(index: Int) {
        guard rows.indices.contains(index) else { return }
        rows[index].state = .failed
    }

    func reset() {
        rows = []
        currentIndex = 0
    }

    nonisolated static func floorAreaM2(of room: CapturedRoom) -> Double {
        room.floors.reduce(0.0) { sum, floor in
            let corners = floor.polygonCorners.map { corner -> simd_float4 in
                floor.transform * simd_float4(corner, 1)
            }
            let points = corners.map { (x: Double($0.x), z: Double($0.z)) }
            guard points.count >= 3 else { return sum }
            var area = 0.0
            for i in points.indices {
                let a = points[i]
                let b = points[(i + 1) % points.count]
                area += a.x * b.z - b.x * a.z
            }
            return sum + abs(area) / 2.0
        }
    }
}