import SwiftUI

struct PendingTourPhotosBanner: View {
    let floorPlan: FloorPlan
    let session: ScanSessionResponse
    let identifierPrefix: String
    let onUploaded: () async -> Void

    @State private var pending: [String: Int] = [:]
    @State private var isUploading = false

    private var refreshKey: String {
        floorPlan.rooms.map { "\($0.roomId)|\($0.captureGroupId ?? "")|\($0.joinedToGroupId ?? "")" }.joined(separator: ",")
            + "#\(floorPlan.photos360?.count ?? 0)"
    }

    var body: some View {
        let total = pending.values.reduce(0, +)
        Group {
            if total > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(format: vuuroLocalized("%lld tour photo(s) are still only on this phone"), total))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(VuuroColor.textPrimary)
                    Text(vuuroLocalized("They were not uploaded with this scan. Upload them now to add them to the tour."))
                        .font(.system(size: 13))
                        .foregroundStyle(VuuroColor.textSecondary)
                    Button {
                        Task { await upload() }
                    } label: {
                        if isUploading {
                            ProgressView()
                        } else {
                            Text(vuuroLocalized("Upload tour photos"))
                        }
                    }
                    .accessibilityIdentifier("\(identifierPrefix).uploadPendingTourPhotos")
                    .buttonStyle(.vuuroOutlineSmall)
                    .disabled(isUploading)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VuuroColor.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
        .task(id: refreshKey) { refresh() }
    }

    @MainActor
    private func refresh() {
        pending = RoomPhotoUploader.pendingPhotoCount(floorPlan: floorPlan, store: .shared)
    }

    @MainActor
    private func upload() async {
        guard !isUploading else { return }
        isUploading = true
        defer { isUploading = false }
        var uploaded = 0
        var failed = 0
        var skipReason: String?
        for groupId in pending.keys.sorted() {
            let outcome = await RoomPhotoUploader.uploadAll(
                captureGroupId: groupId,
                session: session,
                floorPlan: floorPlan,
                store: .shared,
                trigger: "manual_retry"
            )
            uploaded += outcome.photosUploaded
            failed += outcome.photosFailed
            if let reason = outcome.skipReason { skipReason = reason }
        }
        DiagnosticsLog.shared.record(
            "Photo360: manual retry for \(session.id) uploaded \(uploaded), failed \(failed)\(skipReason.map { ", skipped: \($0)" } ?? "")",
            category: failed > 0 || skipReason != nil ? .error : .info
        )
        if let skipReason {
            VuuroToast.shared.show(skipReason)
        } else if failed > 0 {
            VuuroToast.shared.show(String(format: vuuroLocalized("%lld tour photo(s) couldn't be uploaded"), failed))
        } else if uploaded > 0 {
            VuuroToast.shared.show(String(format: vuuroLocalized("%lld tour photo(s) uploaded"), uploaded))
        }
        refresh()
        await onUploaded()
    }
}
