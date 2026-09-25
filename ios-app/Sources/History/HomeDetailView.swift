import SwiftUI

struct HomeDetailView: View {
    let key: HomeKey
    let onAddRooms: (HomeAddRoomsRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ScanHistoryEntry] = []
    @State private var selectedSession: ScanHistoryEntry?
    @State private var addTarget: AddRoomsTarget?
    @State private var showNewFloorPrompt = false
    @State private var newFloorName = ""

    private struct AddRoomsTarget: Identifiable {
        let floor: String
        var id: String { floor }
    }

    private var home: HomeAggregate? {
        HomeAggregator.aggregate(entries).first { $0.key == key }
    }

    var body: some View {
        VStack(spacing: 0) {
            VuuroNavBar(
                title: key.displayName,
                leading: { VuuroNavButton("Close") { dismiss() }.accessibilityIdentifier("homeDetail.close") },
                trailing: { VuuroNavSpacer() }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                    if let home {
                        ForEach(home.floors) { floor in
                            floorSection(floor, home: home)
                        }
                        addFloorButton
                    } else {
                        Text("No scans on this device for this home.")
                            .font(.system(size: 13))
                            .foregroundStyle(VuuroColor.textSecondary)
                            .padding(.horizontal, 20)
                            .padding(.top, 20)
                    }
                    Spacer().frame(height: 32)
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(VuuroColor.bgApp)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { reload() }
        .sheet(item: $selectedSession) { entry in
            NavigationStack {
                ScanResultsReportView(
                    entry: entry,
                    onDelete: { reload() },
                    onContinueScan: { floor in
                        selectedSession = nil
                        onAddRooms(.addToScan(entry, floor: floor))
                        dismiss()
                    }
                )
            }
        }
        .confirmationDialog(
            addTarget.map { $0.floor.isEmpty ? "Add rooms" : "Add rooms on \($0.floor)" } ?? "",
            isPresented: Binding(
                get: { addTarget != nil },
                set: { if !$0 { addTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: addTarget
        ) { target in
            if let latest = home?.mostRecentEntry {
                Button("Add to latest scan (one report)") {
                    onAddRooms(.addToScan(latest, floor: target.floor))
                    dismiss()
                }
                .accessibilityIdentifier("homeDetail.addToLatestScan")
            }
            Button("Start a new visit (separate report)") {
                onAddRooms(.newVisit(makeIdentity(floor: target.floor)))
                dismiss()
            }
            .accessibilityIdentifier("homeDetail.startNewVisit")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("homeDetail.addCancel")
        } message: { _ in
            Text(addChoiceMessage)
        }
        .alert("Which floor?", isPresented: $showNewFloorPrompt) {
            TextField("e.g. Attic, 1st floor", text: $newFloorName)
                .accessibilityIdentifier("homeDetail.newFloorField")
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            Button("Continue") {
                let trimmed = newFloorName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    addTarget = AddRoomsTarget(floor: trimmed)
                }
            }
            .accessibilityIdentifier("homeDetail.newFloorContinue")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("homeDetail.newFloorCancel")
        } message: {
            Text("Name the floor you're about to scan.")
        }
    }

    private var addChoiceMessage: String {
        guard let latest = home?.mostRecentEntry else {
            return "This saves as a new report, grouped under this home."
        }
        let date = Self.dateFormatter.string(from: latest.createdAt)
        return "Adding to the latest scan (\(date)) keeps every floor in one report. A new visit saves as its own report, grouped under this home."
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let home {
                HStack(spacing: 8) {
                    VuuroBadge("\(home.floors.count) \(home.floors.count == 1 ? "floor" : "floors")", style: .info)
                    if home.totalAreaM2 > 0 {
                        VuuroBadge(String(format: "%.1f m\u{00B2}", home.totalAreaM2), style: .neutral)
                    }
                    if home.totalRooms > 0 {
                        VuuroBadge("\(home.totalRooms) \(home.totalRooms == 1 ? "room" : "rooms")", style: .neutral)
                    }
                }
                Text("Every scan of this home, grouped by floor. Add rooms to the latest scan to keep one report, or start a new visit.")
                    .font(.system(size: 13))
                    .foregroundStyle(VuuroColor.textSecondary)
                    .lineSpacing(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private func floorSection(_ floor: FloorGroup, home: HomeAggregate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(floor.displayName ?? "Unassigned")
                    .font(.system(size: 17, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(VuuroColor.textPrimary)
                Text(floorSubtitle(floor))
                    .font(.system(size: 12))
                    .foregroundStyle(VuuroColor.textSecondary)
            }
            .padding(.horizontal, 20)

            VStack(spacing: 8) {
                ForEach(floor.sessions) { session in
                    sessionRow(session)
                }
                Button {
                    addTarget = AddRoomsTarget(floor: floor.displayName ?? "")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Add rooms on this floor")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(VuuroColor.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(VuuroColor.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .accessibilityIdentifier("homeDetail.addRooms.\(floor.id)")
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    private func floorSubtitle(_ floor: FloorGroup) -> String {
        var parts: [String] = []
        if floor.roomCount > 0 {
            parts.append("\(floor.roomCount) \(floor.roomCount == 1 ? "room" : "rooms")")
        }
        if floor.totalAreaM2 > 0 {
            parts.append(String(format: "%.1f m\u{00B2}", floor.totalAreaM2))
        }
        if floor.sessions.count > 1 {
            parts.append("\(floor.sessions.count) sessions")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func sessionRow(_ entry: ScanHistoryEntry) -> some View {
        Button {
            selectedSession = entry
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sessionTitle(entry))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(VuuroColor.textPrimary)
                        .multilineTextAlignment(.leading)
                    Text(sessionSubtitle(entry))
                        .font(.system(size: 12))
                        .foregroundStyle(VuuroColor.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VuuroColor.textTertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VuuroColor.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: VuuroMetrics.cardShadowTightColor, radius: VuuroMetrics.cardShadowTightRadius, x: 0, y: 1)
        }
        .accessibilityIdentifier("homeDetail.session.\(entry.sessionId)")
        .buttonStyle(.plain)
    }

    private func sessionTitle(_ entry: ScanHistoryEntry) -> String {
        if let n = entry.nickname, !n.isEmpty { return n }
        return entry.purpose.displayName
    }

    private func sessionSubtitle(_ entry: ScanHistoryEntry) -> String {
        var parts: [String] = [Self.dateFormatter.string(from: entry.createdAt)]
        if entry.parsedRoomCount > 0 {
            parts.append("\(entry.parsedRoomCount) \(entry.parsedRoomCount == 1 ? "room" : "rooms")")
        }
        if let area = entry.cachedFloorAreaM2, area > 0 {
            parts.append(String(format: "%.1f m\u{00B2}", area))
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var addFloorButton: some View {
        Button {
            newFloorName = ""
            showNewFloorPrompt = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 15, weight: .semibold))
                Text("Add a new floor")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(VuuroColor.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(VuuroColor.bgInset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .accessibilityIdentifier("homeDetail.addNewFloor")
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func makeIdentity(floor: String) -> ScanIdentity {
        ScanIdentity(
            propertyId: key.propertyId,
            unitId: key.unitId,
            organisationId: key.organisationId,
            purpose: home?.mostRecentEntry?.purpose ?? .listing,
            occupied: home?.mostRecentEntry?.occupied ?? false,
            consentObtained: home?.mostRecentEntry?.consentObtained ?? false,
            floor: floor.isEmpty ? nil : floor
        )
    }

    @MainActor
    private func reload() {
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                ScanHistoryStore.shared.all()
            }.value
            entries = loaded
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        f.locale = AppLanguageSettings.effectiveLocale
        return f
    }()
}
