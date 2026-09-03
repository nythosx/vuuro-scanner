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

    private var identityFieldsFilled: Bool {
        !propertyId.trimmingCharacters(in: .whitespaces).isEmpty
            && !unitId.trimmingCharacters(in: .whitespaces).isEmpty
            && !organisationId.trimmingCharacters(in: .whitespaces).isEmpty
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
                Button("Start scan") {
                    onStart(ScanIdentity(
                        propertyId: propertyId,
                        unitId: unitId,
                        organisationId: organisationId,
                        purpose: purpose,
                        occupied: occupied,
                        consentObtained: occupied ? consentObtained : false
                    ))
                }
                .disabled(!canStart)

                if let onStartMultiRoom {
                    Button("Start multi-room scan (fused, experimental)") {
                        onStartMultiRoom(ScanIdentity(
                            propertyId: propertyId,
                            unitId: unitId,
                            organisationId: organisationId,
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
