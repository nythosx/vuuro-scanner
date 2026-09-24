
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
    @State private var floor: String = ""
    @State private var isCheckingHealth = false
    @State private var healthCheckError: AppError?
    @State private var pendingStart: ((ScanIdentity) -> Void)?
    @State private var showReagreeSheet = false

    private let client = ScanServiceClient()

    private var trimmedFloor: String {
        floor.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentIdentity: ScanIdentity {
        ScanIdentity(
            propertyId: trimmedPropertyId,
            unitId: trimmedUnitId,
            organisationId: trimmedOrganisationId,
            purpose: purpose,
            occupied: occupied,
            consentObtained: occupied ? consentObtained : false,
            floor: trimmedFloor.isEmpty ? nil : trimmedFloor
        )
    }

    private var trimmedPropertyId: String { propertyId.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUnitId: String { unitId.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedOrganisationId: String { organisationId.trimmingCharacters(in: .whitespacesAndNewlines) }

    @State private var previouslyUsedPropertyIds: [String] = []
    @State private var previouslyUsedUnitIds: [String] = []
    @State private var previouslyUsedOrganisationIds: [String] = []

    private func loadPreviouslyUsedValues() {
        Task { @MainActor in
            let (propertyIds, unitIds, organisationIds) = await Task.detached(priority: .userInitiated) {
                let entries = ScanHistoryStore.shared.all()
                return (
                    Self.recentDistinctValues(\.propertyId, in: entries),
                    Self.recentDistinctValues(\.unitId, in: entries),
                    Self.recentDistinctValues(\.organisationId, in: entries)
                )
            }.value
            previouslyUsedPropertyIds = propertyIds
            previouslyUsedUnitIds = unitIds
            previouslyUsedOrganisationIds = organisationIds
        }
    }

    private static func recentDistinctValues(_ keyPath: KeyPath<ScanHistoryEntry, String>, in entries: [ScanHistoryEntry]) -> [String] {
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
                    .accessibilityIdentifier("identity.propertyId")
                if !previouslyUsedPropertyIds.isEmpty {
                    suggestionChips(previouslyUsedPropertyIds) { propertyId = $0 }
                }
                TextField("e.g. unit-2b", text: $unitId)
                    .accessibilityIdentifier("identity.unitId")
                if !previouslyUsedUnitIds.isEmpty {
                    suggestionChips(previouslyUsedUnitIds) { unitId = $0 }
                }
                TextField("e.g. org-athome-vastgoed", text: $organisationId)
                    .accessibilityIdentifier("identity.organisationId")
                if !previouslyUsedOrganisationIds.isEmpty {
                    suggestionChips(previouslyUsedOrganisationIds) { organisationId = $0 }
                }
            } header: {
                Text("Unit identity")
            } footer: {
                Text("Enter the property, unit, and organisation this scan belongs to. Tap a suggestion below a field to reuse a value from an earlier scan.")
            }

            Section("Floor") {
                TextField("e.g. Attic, 1st floor, Basement", text: $floor)
                    .accessibilityIdentifier("identity.floor")
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            }

            Section("Purpose") {
                Picker("Purpose", selection: $purpose) {
                    ForEach(ScanPurpose.allCases) { purpose in
                        Text(purpose.displayName).tag(purpose)
                    }
                }
                .accessibilityIdentifier("identity.purpose")
            }

            Section("Occupancy") {
                Toggle("This unit is currently occupied", isOn: $occupied)
                    .accessibilityIdentifier("identity.occupied")
                    .onChange(of: occupied) { _, newValue in
                        if !newValue {
                            consentObtained = false
                        }
                    }

                if occupied {
                    Toggle("Tenant consent obtained for this scan", isOn: $consentObtained)
                        .accessibilityIdentifier("identity.consent")
                    if !consentObtained {
                        Text("Consent is required before scanning an occupied unit.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                Toggle("Guess room type while scanning", isOn: $roomTypeGuessEnabled)
                    .accessibilityIdentifier("identity.roomTypeGuess")
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
                .accessibilityIdentifier("identity.scanOneRoom")
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
                    .accessibilityIdentifier("identity.scanWholeUnit")
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

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("By scanning with this app, you agree to the Terms of Service and Privacy Policy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    NavigationLink("Read Terms of Service & Privacy Policy") {
                        TermsAndPrivacyView()
                    }
                    .accessibilityIdentifier("identity.terms")
                    .font(.caption.weight(.semibold))
                }
            }
        }
        .navigationTitle("New scan")
        .onAppear { loadPreviouslyUsedValues() }
        .sheet(isPresented: $showReagreeSheet) {
            NavigationStack {
                ReagreeTermsView(
                    onAgree: {
                        LegalAgreementStore.recordAgreement()
                        showReagreeSheet = false
                        if let pendingStart {
                            self.pendingStart = nil
                            Task { await startIfHealthy(pendingStart) }
                        }
                    },
                    onDecline: {
                        pendingStart = nil
                        showReagreeSheet = false
                    }
                )
            }
        }
    }

    private func suggestionChips(_ values: [String], onPick: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(values, id: \.self) { value in
                    Button(value) {
                        onPick(value)
                    }
                    .accessibilityIdentifier("identity.suggestion.\(value)")
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16))
    }

    @MainActor
    private func startIfHealthy(_ start: @escaping (ScanIdentity) -> Void) async {
        guard LegalAgreementStore.agreedVersion == LegalDocument.currentVersion else {
            pendingStart = start
            showReagreeSheet = true
            return
        }
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
