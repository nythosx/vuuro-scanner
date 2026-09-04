//
//  CapturedStructureExporter.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see ../Models/ScanIdentity.swift header.
//
//  LIDAR-5/11: exports each room of a StructureBuilder-merged CapturedStructure.
//  Assumes structure.rooms yields CapturedRoom values whose surface.transform
//  already reflects the merged shared frame — unverified, real device is the
//  only way to confirm this (docs/proposals/multi-room-fusion.md).
//

import Foundation
import RoomPlan

@MainActor
enum CapturedStructureExporter {
    /// One export per room, each carrying origin_m — its own bounding-box
    /// min corner in the shared frame, computed before any per-room
    /// re-normalization (kept server-side, additive to origin_m per LIDAR-10's convention).
    static func export(_ structure: CapturedStructure, roomTypeConfirmationsByIdentifier: [UUID: RoomTypeConfirmation] = [:]) -> [RoomPlanCaptureExport] {
        structure.rooms.enumerated().map { index, room in
            let confirmation = roomTypeConfirmationsByIdentifier[room.identifier]
            var export = CapturedRoomExporter.export(room, roomTypeConfirmation: confirmation)
            export.structureOriginM = structureOriginM(for: export)
            #if DEBUG
            logFusionGeometry(roomIndex: index, room: room, export: export)
            #endif
            return export
        }
    }

    private static func structureOriginM(for export: RoomPlanCaptureExport) -> [Double]? {
        let corners = export.floors.compactMap { $0.polygonCorners }.flatMap { $0 }
        guard let minX = corners.map({ $0[0] }).min(),
              let minZ = corners.map({ $0[2] }).min() else { return nil }
        return [minX, minZ]
    }

    #if DEBUG
    private static func logFusionGeometry(roomIndex: Int, room: CapturedRoom, export: RoomPlanCaptureExport) {
        let originText = export.structureOriginM.map { String(format: "(%.2f, %.2f)", $0[0], $0[1]) } ?? "nil"
        let headingText = headingDegrees(for: room).map { String(format: "%.1f", $0) } ?? "n/a"
        DiagnosticsLog.shared.record(
            "Fusion geometry room \(roomIndex + 1): origin_m \(originText), heading \(headingText) deg, floors \(export.floors.count)",
            category: .state
        )
    }

    private static func headingDegrees(for room: CapturedRoom) -> Double? {
        guard let floor = room.floors.first else { return nil }
        let forward = floor.transform.columns.0
        guard forward.x != 0 || forward.z != 0 else { return nil }
        return atan2(Double(forward.z), Double(forward.x)) * 180 / .pi
    }
    #endif
}
