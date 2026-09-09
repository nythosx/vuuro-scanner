
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

    private var identityFieldsFilled: Bool {
        !trimmedPropertyId.isEmpty && !trimmedUnitId.isEmpty && !trimmedOrganisationId.isEmpty
    }

    private var canStart: Bool {
        identityFieldsFilled && (!occupied || consentObtained)
    }

    var body: some View {
        Form {
            Section("Unit identity") {
                TextField("Property ID", text: $propertyId)
                TextField("Unit ID", text: $unitId)
                TextField("Organisation ID", text: $organisationId)
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
                        Text("Start scan")
                    }
                }
                .disabled(!canStart || isCheckingHealth)

                if let onStartMultiRoom {
                    Button {
                        Task { await startIfHealthy(onStartMultiRoom) }
                    } label: {
                        Text("Start multi-room scan (fused, experimental)")
                    }
                    .disabled(!canStart || isCheckingHealth)
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
