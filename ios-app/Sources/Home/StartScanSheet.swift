import SwiftUI

enum ScanStartType { case single, multi }

struct StartScanSheet: View {
    let type: ScanStartType
    let onCancel: () -> Void
    let onStart: (ScanIdentity) -> Void

    @State private var propertyId = ""
    @State private var unitId = ""
    @State private var organisationId = ""
    @State private var purpose: ScanPurpose = .listing
    @State private var occupied = false
    @State private var consentObtained = false
    @State private var roomTypeGuessEnabled = RoomTypeGuessSettings.isEnabled
    @State private var isCheckingHealth = false
    @State private var healthCheckError: AppError?
    @State private var showReagreeSheet = false
    @State private var previouslyUsedPropertyIds: [String] = []
    @State private var previouslyUsedUnitIds: [String] = []
    @State private var previouslyUsedOrganisationIds: [String] = []

    private let client = ScanServiceClient()

    private var trimmedPropertyId: String { propertyId.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUnitId: String { unitId.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedOrganisationId: String { organisationId.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var identityFieldsFilled: Bool {
        !trimmedPropertyId.isEmpty && !trimmedUnitId.isEmpty && !trimmedOrganisationId.isEmpty
    }

    private var canStart: Bool { identityFieldsFilled && (!occupied || consentObtained) }

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

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(VuuroColor.handle)
                .frame(width: 36, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 16)

            HStack {
                Text(type == .multi ? "Whole unit scan" : "Single room scan")
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(VuuroColor.textPrimary)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(VuuroColor.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(VuuroColor.overlayPill.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VuuroSectionLabel(text: "Property details")

                    VuuroInputGroup {
                        VuuroInputRow(leadingIcon: "house", showsDivider: false) {
                            TextField("Property ID", text: $propertyId)
                                .font(.system(size: 15))
                                .tracking(-0.2)
                                .foregroundStyle(VuuroColor.textPrimary)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 20)

                    if !previouslyUsedPropertyIds.isEmpty {
                        VuuroChipRow(items: previouslyUsedPropertyIds) { propertyId = $0 }
                    }

                    VuuroInputGroup {
                        VuuroInputRow(leadingIcon: "building.2", showsDivider: false) {
                            TextField("Unit ID", text: $unitId)
                                .font(.system(size: 15))
                                .tracking(-0.2)
                                .foregroundStyle(VuuroColor.textPrimary)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    if !previouslyUsedUnitIds.isEmpty {
                        VuuroChipRow(items: previouslyUsedUnitIds) { unitId = $0 }
                    }

                    VuuroInputGroup {
                        VuuroInputRow(leadingIcon: "briefcase", showsDivider: false) {
                            TextField("Organisation ID", text: $organisationId)
                                .font(.system(size: 15))
                                .tracking(-0.2)
                                .foregroundStyle(VuuroColor.textPrimary)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    if !previouslyUsedOrganisationIds.isEmpty {
                        VuuroChipRow(items: previouslyUsedOrganisationIds) { organisationId = $0 }
                    }

                    VuuroSectionLabel(text: "Purpose")

                    VuuroInputGroup {
                        VuuroInputRow(leadingIcon: "list.clipboard", showsDivider: false) {
                            Picker("", selection: $purpose) {
                                ForEach(ScanPurpose.allCases) { p in
                                    Text(p.displayName).tag(p)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .tint(VuuroColor.textPrimary)
                        }
                    }
                    .padding(.horizontal, 20)

                    VuuroSectionLabel(text: "Occupancy")

                    VuuroInputGroup {
                        VuuroInputRow(
                            leadingIcon: "person.2",
                            label: "Unit is currently occupied",
                            showsDivider: occupied
                        ) {
                            Toggle("", isOn: $occupied)
                                .labelsHidden()
                                .tint(VuuroColor.lime)
                                .onChange(of: occupied) { _, newValue in
                                    if !newValue { consentObtained = false }
                                }
                        }
                        if occupied {
                            VuuroInputRow(
                                leadingIcon: "signature",
                                label: "Tenant consent obtained",
                                showsDivider: false
                            ) {
                                Toggle("", isOn: $consentObtained)
                                    .labelsHidden()
                                    .tint(VuuroColor.lime)
                            }
                        }
                    }
                    .padding(.horizontal, 20)

                    VuuroSectionLabel(text: "Preferences")

                    VuuroInputGroup {
                        VuuroInputRow(
                            leadingIcon: "wand.and.stars",
                            label: "Guess room type while scanning",
                            showsDivider: false
                        ) {
                            Toggle("", isOn: $roomTypeGuessEnabled)
                                .labelsHidden()
                                .tint(VuuroColor.lime)
                                .onChange(of: roomTypeGuessEnabled) { _, newValue in
                                    RoomTypeGuessSettings.isEnabled = newValue
                                }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)

                    if let healthCheckError {
                        ErrorCodeView(error: healthCheckError)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                    }

                    #if DEBUG
                    VuuroSectionLabel(text: "Build")
                    Text(BuildInfo.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(VuuroColor.textSecondary)
                        .padding(.horizontal, 20)
                    #endif

                    Spacer().frame(height: 12)
                }
            }
            .scrollIndicators(.hidden)

            VStack(spacing: 0) {
                Button {
                    Task { await startIfHealthy() }
                } label: {
                    if isCheckingHealth {
                        ProgressView().tint(.white)
                    } else {
                        Text(type == .multi ? "Start unit scan" : "Start room scan")
                    }
                }
                .buttonStyle(.vuuroPrimary)
                .disabled(!canStart || isCheckingHealth)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .background(VuuroColor.bgApp)
            .overlay(alignment: .top) {
                Rectangle().fill(VuuroColor.borderMed).frame(height: 1)
            }
        }
        .background(VuuroColor.bgApp)
        .onAppear { loadPreviouslyUsedValues() }
        .sheet(isPresented: $showReagreeSheet) {
            NavigationStack {
                ReagreeTermsView(
                    onAgree: {
                        LegalAgreementStore.recordAgreement()
                        showReagreeSheet = false
                        Task { await startIfHealthy() }
                    },
                    onDecline: { showReagreeSheet = false }
                )
            }
        }
    }

    private func loadPreviouslyUsedValues() {
        Task { @MainActor in
            let (p, u, o) = await Task.detached(priority: .userInitiated) {
                let entries = ScanHistoryStore.shared.all()
                return (
                    Self.recentDistinctValues(\.propertyId, in: entries),
                    Self.recentDistinctValues(\.unitId, in: entries),
                    Self.recentDistinctValues(\.organisationId, in: entries)
                )
            }.value
            previouslyUsedPropertyIds = p
            previouslyUsedUnitIds = u
            previouslyUsedOrganisationIds = o
        }
    }

    private static func recentDistinctValues(
        _ keyPath: KeyPath<ScanHistoryEntry, String>,
        in entries: [ScanHistoryEntry]
    ) -> [String] {
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

    @MainActor
    private func startIfHealthy() async {
        guard LegalAgreementStore.agreedVersion == LegalDocument.currentVersion else {
            showReagreeSheet = true
            return
        }
        #if DEBUG
        if FakeLidarMode.isEnabled {
            healthCheckError = nil
            onStart(currentIdentity)
            return
        }
        #endif
        isCheckingHealth = true
        defer { isCheckingHealth = false }
        do {
            try await client.checkHealth()
            healthCheckError = nil
            onStart(currentIdentity)
        } catch {
            healthCheckError = AppError(site: .healthCheck, underlying: error)
        }
    }
}