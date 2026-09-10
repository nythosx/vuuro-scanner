
import SwiftUI

struct IdentityIntakeScreen: View {
    var onStart: (ScanIdentity) -> Void
    var onStartMultiRoom: ((ScanIdentity) -> Void)? = nil

    @State private var propertyId = ""
    @State private var unitId = ""
    @State private var organisationId = ""
    @State private var purpose: ScanPurpose = .listing
    @State private var occupied = false
    @State private var consentObtained = false
    @State private var roomTypeGuessEnabled = RoomTypeGuessSettings.isEnabled
    @State private var isCheckingHealth = false
    @State private var healthCheckError: AppError?

    private let client = ScanServiceClient()

    private var currentIdentity: ScanIdentity {
        ScanIdentity(
            propertyId: trimmedPropertyId,
            unitId: trimmedUnitId,
            organisationId: trimmedOrganisationId,
            purpose: purpose,
            occupied: occupied,
            consentObtained: occupied ? consentObtained : false
        )
    }

    private var trimmedPropertyId: String { propertyId.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUnitId: String { unitId.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedOrganisationId: String { organisationId.trimmingCharacters(in: .whitespacesAndNewlines) }

    @State private var previouslyUsedPropertyIds: [String] = []
    @State private var previouslyUsedUnitIds: [String] = []
    @State private var previouslyUsedOrganisationIds: [String] = []

    private func loadPreviouslyUsedValues() {
        let entries = ScanHistoryStore.shared.all()
        previouslyUsedPropertyIds = recentDistinctValues(\.propertyId, in: entries)
        previouslyUsedUnitIds = recentDistinctValues(\.unitId, in: entries)
        previouslyUsedOrganisationIds = recentDistinctValues(\.organisationId, in: entries)
    }

    private func recentDistinctValues(_ keyPath: KeyPath<ScanHistoryEntry, String>, in entries: [ScanHistoryEntry]) -> [String] {
        var seen = Set<String>()
        var values: [String] = []
        for entry in entries {
            let value = entry[keyPath: keyPath]
            if !value.isEmpty, seen.insert(value).inserted {
                values.append(value)
            }
            if values.count == 5 { break }
        }
        return values
    }

    private var identityFieldsFilled: Bool {
        !trimmedPropertyId.isEmpty && !trimmedUnitId.isEmpty && !trimmedOrganisationId.isEmpty
    }

    private var canStart: Bool {
        identityFieldsFilled && (!occupied || consentObtained)
    }

    private var debugFakeCaptureActive: Bool {
        #if DEBUG
        FakeLidarMode.isEnabled
        #else
        false
        #endif
    }

    var body: some View {
        if !DeviceCapability.isRoomPlanSupported && !debugFakeCaptureActive {
            UnsupportedDeviceScreen()
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField("e.g. prop-oosterpark-14", text: $propertyId)
                if !previouslyUsedPropertyIds.isEmpty {
                    suggestionChips(previouslyUsedPropertyIds) { propertyId = $0 }
                }
                TextField("e.g. unit-2b", text: $unitId)
                if !previouslyUsedUnitIds.isEmpty {
                    suggestionChips(previouslyUsedUnitIds) { unitId = $0 }
                }
                TextField("e.g. org-athome-vastgoed", text: $organisationId)
                if !previouslyUsedOrganisationIds.isEmpty {
                    suggestionChips(previouslyUsedOrganisationIds) { organisationId = $0 }
                }
            } header: {
                Text("Unit identity")
            } footer: {
                Text("Enter the property, unit, and organisation this scan belongs to. Tap a suggestion below a field to reuse a value from an earlier scan.")
            }

            Section("Purpose") {
                Picker("Purpose", selection: $purpose) {
                    ForEach(ScanPurpose.allCases) { purpose in
                        Text(purpose.displayName).tag(purpose)
                    }
                }
            }

            Section("Occupancy") {
                Toggle("This unit is currently occupied", isOn: $occupied)
                    .onChange(of: occupied) { _, newValue in
                        if !newValue {
                            consentObtained = false
                        }
                    }

                if occupied {
                    Toggle("Tenant consent obtained for this scan", isOn: $consentObtained)
                    if !consentObtained {
                        Text("Consent is required before scanning an occupied unit.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                Toggle("Guess room type while scanning", isOn: $roomTypeGuessEnabled)
                    .tint(VuuroColor.accentLime)
                    .onChange(of: roomTypeGuessEnabled) { _, newValue in
                        RoomTypeGuessSettings.isEnabled = newValue
                    }
                Text("Shows a quick bathroom/bedroom/kitchen/… guess on screen during capture — tap ✓ or ✗, or turn this off entirely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    Task { await startIfHealthy(onStart) }
                } label: {
                    if isCheckingHealth {
                        ProgressView()
                    } else {
                        Text("Scan one room")
                    }
                }
                .buttonStyle(.vuuroPrimary)
                .disabled(!canStart || isCheckingHealth)
                Text("For a single room by itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let onStartMultiRoom {
                    Button {
                        Task { await startIfHealthy(onStartMultiRoom) }
                    } label: {
                        Text("Scan a whole unit")
                    }
                    .buttonStyle(.vuuroSecondary)
                    .disabled(!canStart || isCheckingHealth)
                    Text("Walk through and capture every room in one visit; they're combined into one floor plan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let healthCheckError {
                    ErrorCodeView(error: healthCheckError)
                }
            }

            #if DEBUG
  
            Section {
                Text(BuildInfo.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            #endif
        }
        .navigationTitle("New scan")
        .onAppear { loadPreviouslyUsedValues() }
    }

    private func suggestionChips(_ values: [String], onPick: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(values, id: \.self) { value in
                    Button(value) {
                        onPick(value)
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16))
    }

    @MainActor
    private func startIfHealthy(_ start: (ScanIdentity) -> Void) async {
        isCheckingHealth = true
        defer { isCheckingHealth = false }
        do {
            try await client.checkHealth()
            healthCheckError = nil
            start(currentIdentity)
        } catch {
            healthCheckError = AppError(site: .healthCheck, underlying: error)
        }
    }
}
