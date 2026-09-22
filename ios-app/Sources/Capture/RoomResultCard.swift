import SwiftUI

struct ObjectChangeKey: Hashable {
    let roomId: String
    let objectId: String
}

struct PendingObjectChange: Equatable {
    var customName: String?
    var customNameChanged: Bool = false
    var excluded: Bool?
    var delete: Bool?
}

struct ObjectChangeRequest: Encodable {
    let roomId: String
    let objectId: String
    let customName: String?
    let customNameChanged: Bool
    let excluded: Bool?
    let delete: Bool?

    enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case objectId = "object_id"
        case customName = "custom_name"
        case excluded
        case delete
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(roomId, forKey: .roomId)
        try container.encode(objectId, forKey: .objectId)
        if customNameChanged {
            try container.encode(customName, forKey: .customName)
        }
        try container.encodeIfPresent(excluded, forKey: .excluded)
        try container.encodeIfPresent(delete, forKey: .delete)
    }
}

enum ObjectCategoryCatalog {
    static let knownCategories: [(id: String, name: String)] = [
        ("bed", "Bed"),
        ("sofa", "Sofa"),
        ("chair", "Chair"),
        ("table", "Table"),
        ("desk", "Desk"),
        ("storage", "Storage"),
        ("refrigerator", "Refrigerator"),
        ("stove", "Stove"),
        ("oven", "Oven"),
        ("dishwasher", "Dishwasher"),
        ("sink", "Sink"),
        ("toilet", "Toilet"),
        ("bathtub", "Bathtub"),
        ("washerDryer", "Washer/Dryer"),
        ("television", "Television"),
        ("fireplace", "Fireplace"),
        ("stairs", "Stairs"),
        ("other", "Other"),
    ]

    static func displayName(for category: String) -> String {
        let normalized = category.lowercased().replacingOccurrences(of: "_", with: "")
        for entry in knownCategories where entry.id.lowercased().replacingOccurrences(of: "_", with: "") == normalized {
            return entry.name
        }
        return category.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func systemImage(for category: String) -> String {
        switch category.lowercased() {
        case "bed": return "bed.double"
        case "sofa": return "sofa"
        case "chair": return "chair"
        case "table", "desk": return "table.furniture"
        case "storage": return "cabinet"
        case "refrigerator": return "refrigerator"
        case "stove", "oven": return "stove"
        case "dishwasher": return "dishwasher"
        case "sink": return "sink"
        case "toilet": return "toilet"
        case "bathtub": return "bathtub"
        case "washerdryer", "washer_dryer": return "washer"
        case "television": return "tv"
        case "fireplace": return "fireplace"
        case "stairs": return "figure.stairs"
        default: return "cube"
        }
    }
}

struct RoomResultCard: View {
    let room: FloorPlan.Room
    var showsRibbon: Bool = false
    var isFused: Bool = false
    let photos: [FloorPlan.Photo]
    let notes: [FloorPlan.Note]
    let session: ScanSessionResponse
    var pendingObjectChanges: [ObjectChangeKey: PendingObjectChange] = [:]
    var onObjectChange: ((ObjectChangeKey, PendingObjectChange?) -> Void)? = nil

    @State private var renameTarget: ObjectChangeKey?
    @State private var renameDraft: String = ""
    @State private var categoryTarget: ObjectChangeKey?

    private var editingEnabled: Bool { onObjectChange != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            metrics
            VuuroQualityBar(score: room.coverage.score)
            if !visibleObjects.isEmpty || editingEnabled {
                objectsSection
            }
            if !photos.isEmpty || !notes.isEmpty {
                attachments
            }
            disclaimer
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VuuroColor.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: VuuroMetrics.cardShadowTightColor, radius: VuuroMetrics.cardShadowTightRadius, x: 0, y: 1)
        .shadow(color: VuuroMetrics.cardShadowColor, radius: VuuroMetrics.cardShadowRadius, x: 0, y: 4)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .alert("Rename object", isPresented: renameBinding) {
            TextField("Name", text: $renameDraft)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Give this object a name you'll recognize in the floor plan.")
        }
        .confirmationDialog("Object type", isPresented: categoryBinding, titleVisibility: .visible) {
            ForEach(ObjectCategoryCatalog.knownCategories, id: \.id) { entry in
                Button(entry.name) { commitCategoryChange(entry.name) }
            }
            Button("Cancel", role: .cancel) { categoryTarget = nil }
        }
    }

    private var visibleObjects: [FloorPlan.CapturedObject] {
        room.objects.filter { object in
            let key = ObjectChangeKey(roomId: room.roomId, objectId: object.objectId)
            if let change = pendingObjectChanges[key] {
                if change.delete == true { return false }
            }
            return true
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var categoryBinding: Binding<Bool> {
        Binding(get: { categoryTarget != nil }, set: { if !$0 { categoryTarget = nil } })
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(room.label)
                        .font(.system(size: 18, weight: .bold))
                        .tracking(-0.3)
                        .foregroundStyle(VuuroColor.textPrimary)
                    if showsRibbon {
                        VuuroRibbon(text: "FUSED")
                    }
                }
                if let subtitle = subtitleText {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(VuuroColor.textSecondary)
                }
            }
            Spacer(minLength: 0)
            badge
        }
    }

    private var subtitleText: String? {
        if let confirmed = room.roomType?.confirmed, !confirmed.isEmpty {
            return RoomTypeClassifier.displayName(for: confirmed)
        }
        if let guess = room.roomType?.guess, !guess.isEmpty {
            return "\(RoomTypeClassifier.displayName(for: guess)) (suggested)"
        }
        return nil
    }

    @ViewBuilder
    private var badge: some View {
        if room.coverage.score < 80 || room.confidence.lowercased() == "low" {
            VuuroBadge("Low confidence", systemImage: "exclamationmark.triangle.fill", style: .warning)
        } else if let confirmed = room.roomType?.confirmed, !confirmed.isEmpty {
            VuuroBadge(RoomTypeClassifier.displayName(for: confirmed), style: .info)
        } else {
            VuuroBadge("Captured", style: .good)
        }
    }

    private var metrics: some View {
        VuuroRoomMetricGrid(items: [
            .init(value: String(format: "%.1f", room.floorAreaM2), unit: "m\u{00B2}", label: "Area"),
            .init(value: String(format: "%.1f", room.perimeterM), unit: "m", label: "Perimeter"),
            .init(value: heightText, unit: room.heightM == nil ? nil : "m", label: "Height"),
        ])
    }

    private var heightText: String {
        guard let height = room.heightM, height > 0 else { return "\u{2014}" }
        return String(format: "%.1f", height)
    }

    private var objectsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().background(VuuroColor.borderSoft)
            HStack {
                Text("Objects")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(VuuroColor.textSecondary)
                Spacer(minLength: 0)
                Text("\(visibleObjects.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VuuroColor.textSecondary)
            }
            if visibleObjects.isEmpty {
                Text(editingEnabled ? "No objects detected in this room." : "No objects.")
                    .font(.system(size: 12))
                    .foregroundStyle(VuuroColor.textSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(visibleObjects, id: \.objectId) { object in
                        objectRow(object)
                        if object.objectId != visibleObjects.last?.objectId {
                            Divider().background(VuuroColor.borderSoft)
                        }
                    }
                }
                .background(VuuroColor.bgInset)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func objectRow(_ object: FloorPlan.CapturedObject) -> some View {
        let key = ObjectChangeKey(roomId: room.roomId, objectId: object.objectId)
        let change = pendingObjectChanges[key]
        let excluded = change?.excluded ?? object.excluded
        let name = (change?.customNameChanged == true) ? change?.customName : object.customName
        let displayName = (name?.isEmpty == false ? name! : ObjectCategoryCatalog.displayName(for: object.category))
        let renamed = (name?.isEmpty == false) && name != object.category

        let icon = ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(VuuroColor.bgCard)
            Image(systemName: ObjectCategoryCatalog.systemImage(for: object.category))
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(VuuroColor.textPrimary)
        }
        .frame(width: 36, height: 36)
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(VuuroColor.borderSoft, lineWidth: 1)
        )
        .opacity(excluded ? 0.4 : 1)

        return HStack(spacing: 10) {
            if editingEnabled {
                Button {
                    categoryTarget = key
                } label: {
                    icon
                }
                .buttonStyle(.plain)
            } else {
                icon
            }

            VStack(alignment: .leading, spacing: 1) {
                Button {
                    guard editingEnabled else { return }
                    renameTarget = key
                    renameDraft = name ?? ""
                } label: {
                    HStack(spacing: 5) {
                        Text(displayName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(VuuroColor.textPrimary)
                            .lineLimit(1)
                        if renamed {
                            Text("\u{00B7} was \"\(ObjectCategoryCatalog.displayName(for: object.category))\"")
                                .font(.system(size: 10))
                                .foregroundStyle(VuuroColor.textTertiary)
                                .lineLimit(1)
                        }
                        if editingEnabled {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(VuuroColor.textTertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!editingEnabled)
                .opacity(excluded ? 0.5 : 1)

                Text(objectMeta(object, excluded: excluded))
                    .font(.system(size: 10))
                    .foregroundStyle(objectMetaColor(object, excluded: excluded))
            }

            Spacer(minLength: 0)

            if editingEnabled {
                Toggle("", isOn: Binding(
                    get: { !excluded },
                    set: { newIncluded in
                        var updated = change ?? PendingObjectChange()
                        updated.excluded = !newIncluded
                        onObjectChange?(key, updated)
                    }
                ))
                .labelsHidden()
                .tint(VuuroColor.accentLime)
                .scaleEffect(0.85)

                Button {
                    var updated = change ?? PendingObjectChange()
                    updated.delete = true
                    onObjectChange?(key, updated)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(VuuroColor.danger)
                        .frame(width: 30, height: 30)
                        .background(VuuroColor.danger.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func objectMeta(_ object: FloorPlan.CapturedObject, excluded: Bool) -> String {
        if excluded { return "Excluded from export" }
        if object.confidence.lowercased() == "low" { return "Low confidence \u{00B7} tap to rename" }
        return "\(object.confidence.capitalized) confidence"
    }

    private func objectMetaColor(_ object: FloorPlan.CapturedObject, excluded: Bool) -> Color {
        if excluded { return VuuroColor.danger }
        if object.confidence.lowercased() == "low" { return VuuroColor.warningText }
        return VuuroColor.textSecondary
    }

    private func commitRename() {
        guard let key = renameTarget else { return }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = pendingObjectChanges[key] ?? PendingObjectChange()
        updated.customName = trimmed.isEmpty ? nil : trimmed
        updated.customNameChanged = true
        onObjectChange?(key, updated)
        renameTarget = nil
        renameDraft = ""
    }

    private func commitCategoryChange(_ newName: String) {
        guard let key = categoryTarget else { return }
        var updated = pendingObjectChanges[key] ?? PendingObjectChange()
        updated.customName = newName
        updated.customNameChanged = true
        onObjectChange?(key, updated)
        categoryTarget = nil
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().background(VuuroColor.borderSoft)
            RoomAttachmentsList(session: session, photos: photos, notes: notes)
        }
    }

    private var disclaimer: some View {
        Text("Indicative. NEN2580-inspired, not certified.")
            .font(.system(size: 11))
            .foregroundStyle(VuuroColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
            .overlay(alignment: .top) {
                Rectangle().fill(VuuroColor.borderSoft).frame(height: 1)
            }
    }
}
