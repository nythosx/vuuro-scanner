import RoomPlan
import SwiftUI

struct CapturedRoomsListView: View {
    @ObservedObject var coordinator: MultiRoomCaptureCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDeleteId: UUID?
    @State private var retryTargetId: UUID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(coordinator.capturedRooms.enumerated()), id: \.element.identifier) { index, room in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(label(for: index))
                                    VuuroBadge("Captured", systemImage: "checkmark", style: .good)
                                }
                                Text("\(room.walls.count) wall(s), \(room.floors.count) floor(s)")
                                    .font(VuuroFont.body(12))
                                    .foregroundStyle(VuuroColor.textSecondary)
                            }
                            Spacer()
                            Button { retryTargetId = room.identifier } label: {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            .buttonStyle(VuuroIconButtonStyle(tint: VuuroColor.textPrimary, background: VuuroColor.surfaceMuted))
                            Button { pendingDeleteId = room.identifier } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(VuuroIconButtonStyle(tint: VuuroColor.danger, background: VuuroColor.danger.opacity(0.14)))
                        }
                    }
                }
                Section {
                    Button {
                        DiagnosticsLog.shared.record("Add room tapped from captured-rooms list (multi-room)", category: .info)
                        dismiss()
                    } label: {
                        Label("Scan Another Room", systemImage: "plus.circle")
                    }
                    .buttonStyle(.vuuroSecondary)
                }
            }
            .navigationTitle("Captured Rooms")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(
                "Delete this room?",
                isPresented: Binding(
                    get: { pendingDeleteId != nil },
                    set: { if !$0 { pendingDeleteId = nil } }
                )
            ) {
                Button("Delete", role: .destructive) {
                    if let id = pendingDeleteId, let index = coordinator.capturedRooms.firstIndex(where: { $0.identifier == id }) {
                        coordinator.removeCapturedRoom(at: index)
                        VuuroToast.shared.show(String(localized: "Room deleted"))
                    }
                    pendingDeleteId = nil
                }
                Button("Cancel", role: .cancel) { pendingDeleteId = nil }
            } message: {
                Text("This room will be removed from the unit and won't be included in the final upload.")
            }
            .sheet(item: retryTargetBinding) { target in
                RetryReasonSheet(
                    roomLabel: label(forId: target.id),
                    onCancel: { retryTargetId = nil },
                    onConfirm: { reason in
                        if let reason, !reason.isEmpty {
                            DiagnosticsLog.shared.record(
                                "Retry reason (\(label(forId: target.id))): \(reason)",
                                category: .info
                            )
                        }
                        if let index = coordinator.capturedRooms.firstIndex(where: { $0.identifier == target.id }) {
                            coordinator.removeCapturedRoom(at: index)
                        }
                        retryTargetId = nil
                        VuuroToast.shared.show(String(localized: "Room removed — rescan it now"))
                        DispatchQueue.main.async {
                            dismiss()
                        }
                    }
                )
            }
        }
    }

    private struct RetryTarget: Identifiable {
        let id: UUID
    }

    private var retryTargetBinding: Binding<RetryTarget?> {
        Binding(
            get: { retryTargetId.map(RetryTarget.init) },
            set: { retryTargetId = $0?.id }
        )
    }

    private func label(for index: Int) -> String {
        if coordinator.roomTypeConfirmations.indices.contains(index),
           let value = coordinator.roomTypeConfirmations[index]?.value {
            return value.capitalized
        }
        return "Room \(index + 1)"
    }

    private func label(forId id: UUID) -> String {
        guard let index = coordinator.capturedRooms.firstIndex(where: { $0.identifier == id }) else {
            return "this room"
        }
        return label(for: index)
    }
}

private struct RetryReasonSheet: View {
    let roomLabel: String
    let onCancel: () -> Void
    let onConfirm: (String?) -> Void

    @State private var reason = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("Why are you retrying \(roomLabel)? Optional — leave blank and just tap Retry.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ZStack(alignment: .topLeading) {
                    if reason.isEmpty {
                        Text("e.g. missed a corner, wrong room type, walls look off…")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                    }
                    TextEditor(text: $reason)
                        .frame(minHeight: 120)
                }
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                Spacer()
            }
            .padding()
            .navigationTitle("Retry room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Retry") {
                        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                        onConfirm(trimmed.isEmpty ? nil : trimmed)
                    }
                }
            }
        }
    }
}
