import SwiftUI

struct RoomActionAlerts: ViewModifier {
    @Binding var floorTarget: FloorPlan.Room?
    @Binding var deleteTarget: FloorPlan.Room?
    @Binding var floorDraft: String
    let onSaveFloor: (FloorPlan.Room, String?) -> Void
    let onDelete: (FloorPlan.Room) -> Void

    private var showsFloorPrompt: Binding<Bool> {
        Binding(get: { floorTarget != nil }, set: { if !$0 { floorTarget = nil } })
    }

    private var showsDeleteConfirmation: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    func body(content: Content) -> some View {
        content
            .alert("Which floor is this room on?", isPresented: showsFloorPrompt) {
                TextField("e.g. Attic, 1st floor", text: $floorDraft)
                    .accessibilityIdentifier("roomCard.floorField")
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                Button("Save") {
                    if let room = floorTarget {
                        let trimmed = FloorValidation.sanitized(floorDraft)
                        onSaveFloor(room, trimmed.isEmpty ? nil : trimmed)
                    }
                    floorTarget = nil
                }
                .accessibilityIdentifier("roomCard.floorSave")
                Button("Cancel", role: .cancel) {
                    floorTarget = nil
                }
            } message: {
                Text("Leave it empty to clear the floor.")
            }
            .alert("Delete this room?", isPresented: showsDeleteConfirmation) {
                Button("Delete room", role: .destructive) {
                    if let room = deleteTarget {
                        onDelete(room)
                    }
                    deleteTarget = nil
                }
                .accessibilityIdentifier("roomCard.deleteConfirm")
                Button("Cancel", role: .cancel) {
                    deleteTarget = nil
                }
            } message: {
                Text("The room is removed from this report and its plan. Notes and photos for this room move to the whole unit.")
            }
    }
}
