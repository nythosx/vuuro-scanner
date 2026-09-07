import RoomPlan
import SwiftUI

// LIDAR retry/delete/add: shown mid-walkthrough from the "Rooms (N)" button.
struct CapturedRoomsListView: View {
    @ObservedObject var coordinator: MultiRoomCaptureCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDeleteIndex: Int?
    @State private var retryTargetIndex: Int?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(coordinator.capturedRooms.enumerated()), id: \.offset) { index, room in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(label(for: index))
                                Text("\(room.walls.count) wall(s), \(room.floors.count) floor(s)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Retry") { retryTargetIndex = index }
                                .buttonStyle(.bordered)
                            Button("Delete", role: .destructive) { pendingDeleteIndex = index }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                Section {
                    Button {
                        #if DEBUG
                        DiagnosticsLog.shared.record("Add room tapped from captured-rooms list (multi-room)", category: .info)
                        #endif
                        dismiss()
                    } label: {
                        Label("Scan Another Room", systemImage: "plus.circle")
                    }
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
                    get: { pendingDeleteIndex != nil },
                    set: { if !$0 { pendingDeleteIndex = nil } }
                )
            ) {
                Button("Delete", role: .destructive) {
                    if let index = pendingDeleteIndex {
                        coordinator.removeCapturedRoom(at: index)
                    }
                    pendingDeleteIndex = nil
                }
                Button("Cancel", role: .cancel) { pendingDeleteIndex = nil }
            } message: {
                Text("This room will be removed from the unit and won't be included in the final upload.")
            }
            .sheet(item: retryTargetBinding) { target in
                RetryReasonSheet(
                    roomLabel: label(for: target.index),
                    onCancel: { retryTargetIndex = nil },
                    onConfirm: { reason in
                        if let reason, !reason.isEmpty {
                            #if DEBUG
                            DiagnosticsLog.shared.record(
                                "Retry reason (\(label(for: target.index))): \(reason)",
                                category: .info
                            )
                            #endif
                        }
                        coordinator.removeCapturedRoom(at: target.index)
                        retryTargetIndex = nil
                        DispatchQueue.main.async {
                            dismiss()
                        }
                    }
                )
            }
        }
    }

    // .sheet(item:) needs an Identifiable — wraps the plain Int index so the
    // sheet still knows which room it's retrying without a second state var.
    private struct RetryTarget: Identifiable {
        let index: Int
        var id: Int { index }
    }

    private var retryTargetBinding: Binding<RetryTarget?> {
        Binding(
            get: { retryTargetIndex.map(RetryTarget.init) },
            set: { retryTargetIndex = $0?.index }
        )
    }

    private func label(for index: Int) -> String {
        if coordinator.roomTypeConfirmations.indices.contains(index),
           let value = coordinator.roomTypeConfirmations[index]?.value {
            return value.capitalized
        }
        return "Room \(index + 1)"
    }
}

// Optional reason for retrying a room, per Mark's debugging ask: if left
// blank, Cancel and Retry both proceed with no input required (Cancel backs
// out entirely, Retry drops the room with no reason logged). A filled-in
// reason gets written to DiagnosticsLog so it's sitting in the bug-icon
// export already, not something Mark has to separately ask about after the
// fact when he's testing multi-room fusion and isn't satisfied with a result.
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
