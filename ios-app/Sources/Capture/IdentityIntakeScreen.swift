//
//  IdentityIntakeScreen.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see ../Models/ScanIdentity.swift header.
//

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

    private var trimmedPropertyId: String { propertyId.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUnitId: String { unitId.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedOrganisationId: String { organisationId.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var identityFieldsFilled: Bool {
        !trimmedPropertyId.isEmpty && !trimmedUnitId.isEmpty && !trimmedOrganisationId.isEmpty
    }

    /// Mirrors the Scan Service's own gate (hard constraint #3): if occupied,
    /// consent must be explicitly recorded here, not assumed. This is the
    /// client-side half of the same rule `public/index.php` enforces with a
    /// `403 consent_required` — belt and suspenders, not a substitute for it.
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
                Button("Start scan") {
                    onStart(ScanIdentity(
                        propertyId: trimmedPropertyId,
                        unitId: trimmedUnitId,
                        organisationId: trimmedOrganisationId,
                        purpose: purpose,
                        occupied: occupied,
                        consentObtained: occupied ? consentObtained : false
                    ))
                }
                .disabled(!canStart)

                if let onStartMultiRoom {
                    Button("Start multi-room scan (fused, experimental)") {
                        onStartMultiRoom(ScanIdentity(
                            propertyId: trimmedPropertyId,
                            unitId: trimmedUnitId,
                            organisationId: trimmedOrganisationId,
                            purpose: purpose,
                            occupied: occupied,
                            consentObtained: occupied ? consentObtained : false
                        ))
                    }
                    .disabled(!canStart)
                }
            }

            #if DEBUG
            // Mark's 2026-09-02 request: this is the first screen of every
            // session, so a screenshot of it carries "version plus who am I
            // talking to" without him having to ask for it separately.
            Section {
                Text(BuildInfo.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            #endif
        }
        .navigationTitle("New scan")
    }
}
