//
//  IdentityIntakeScreen.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see ../Models/ScanIdentity.swift header.
//
//  Closes ios-app/README.md checklist item 6: VuuroScanApp used to hardcode
//  `occupied: false` with no real consent step behind it. This is the real
//  (if minimal) property/unit/org + occupied/consent form that produces a
//  ScanIdentity the rest of the app can trust — not a placeholder. There is
//  still no Vuuro account/property picker (out of scope until API coupling,
//  per CLAUDE.md); this is manual entry, one deliberate step up from a
//  hardcoded constant.
//

import SwiftUI

struct IdentityIntakeScreen: View {
    var onStart: (ScanIdentity) -> Void

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
            }
        }
        .navigationTitle("New scan")
    }
}
