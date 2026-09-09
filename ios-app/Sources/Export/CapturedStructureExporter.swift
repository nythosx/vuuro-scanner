
import RoomPlan

enum CapturedStructureExporter {
    static func export(_ structure: CapturedStructure, roomTypeConfirmationsByIdentifier: [UUID: RoomTypeConfirmation] = [:], roomWalkPathsByIdentifier: [UUID: [[Double]]] = [:]) -> [RoomPlanCaptureExport] {
        structure.rooms.map { room in
            let confirmation = roomTypeConfirmationsByIdentifier[room.identifier]
            let walkPath = roomWalkPathsByIdentifier[room.identifier]
            var export = CapturedRoomExporter.export(room, roomTypeConfirmation: confirmation, walkPath: walkPath)
            export.structureOriginM = structureOriginM(for: export)
            return export
        }
    }

    private static func structureOriginM(for export: RoomPlanCaptureExport) -> [Double]? {
        let corners = export.floors.compactMap { $0.polygonCorners }.flatMap { $0 }
        guard let minX = corners.map({ $0[0] }).min(),
              let minZ = corners.map({ $0[2] }).min() else { return nil }
        return [minX, minZ]
    }
}
