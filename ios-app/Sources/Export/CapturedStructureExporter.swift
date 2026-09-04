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

import RoomPlan

enum CapturedStructureExporter {
    /// One export per room, each carrying origin_m — its own bounding-box
    /// min corner in the shared frame, computed before any per-room
    /// re-normalization (kept server-side, additive to origin_m per LIDAR-10's convention).
    static func export(_ structure: CapturedStructure, roomTypeConfirmationsByIdentifier: [UUID: RoomTypeConfirmation] = [:]) -> [RoomPlanCaptureExport] {
        structure.rooms.map { room in
            let confirmation = roomTypeConfirmationsByIdentifier[room.identifier]
            var export = CapturedRoomExporter.export(room, roomTypeConfirmation: confirmation)
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
