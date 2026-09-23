import SwiftUI

struct MissingItemSheet: View {
    let session: ScanSessionResponse
    let room: FloorPlan.Room?
    let onSaved: (FloorPlan) -> Void
    let onCancel: () -> Void

    @State private var kind: MissingKind = .skylight
    @State private var note: String = ""
    @State private var isSaving = false
    @State private var error: AppError?

    private let client = ScanServiceClient()

    enum MissingKind: String, CaseIterable, Identifiable {
        case skylight, window, door, opening, object, other
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .skylight: return "Skylight / roof window"
            case .window: return "Window"
            case .door: return "Door"
            case .opening: return "Opening"
            case .object: return "Furniture / fixture"
            case .other: return "Other"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What was missed?") {
                    Picker("Type", selection: $kind) {
                        ForEach(MissingKind.allCases) { k in
                            Text(k.displayName).tag(k)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Notes") {
                    TextField(
                        "Describe what the scan missed",
                        text: $note,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                }

                if let room {
                    Section("Attach to") {
                        Text(room.roomType?.confirmed.map { RoomTypeClassifier.displayName(for: $0) } ?? room.label)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error {
                    Section {
                        ErrorCodeView(error: error)
                    }
                }
            }
            .navigationTitle("Add missing item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task { await save() }
                        }
                        .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    @MainActor
    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = "[\(kind.displayName)] \(trimmed)"
        do {
            let updated = try await client.addNote(
                sessionId: session.id,
                accessToken: session.accessToken,
                text: text,
                roomId: room?.roomId,
                tags: [.missingItem]
            )
            onSaved(updated)
        } catch is CancellationError {
        } catch {
            self.error = AppError(site: .noteAdd, underlying: error)
        }
    }
}
