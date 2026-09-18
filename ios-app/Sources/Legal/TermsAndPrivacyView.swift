import SwiftUI

struct TermsAndPrivacyView: View {
    private enum Document: String, CaseIterable, Identifiable {
        case terms
        case privacy

        var id: String { rawValue }

        var title: String {
            switch self {
            case .terms: return "Terms of Service"
            case .privacy: return "Privacy Policy"
            }
        }

        var sections: [LegalSection] {
            switch self {
            case .terms: return LegalDocument.termsOfService
            case .privacy: return LegalDocument.privacyPolicy
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Document = .terms

    var body: some View {
        VStack(spacing: 0) {
            Picker("Document", selection: $selected) {
                ForEach(Document.allCases) { document in
                    Text(document.title).tag(document)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: VuuroMetrics.contentSpacing) {
                    Text("Version \(LegalDocument.currentVersion) — effective \(LegalDocument.effectiveDate)")
                        .font(VuuroFont.body(12, weight: .semibold))
                        .foregroundStyle(VuuroColor.textSecondary)

                    ForEach(selected.sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.heading)
                                .font(VuuroFont.display(15))
                                .foregroundStyle(VuuroColor.textPrimary)
                            Text(section.body)
                                .font(VuuroFont.body(14))
                                .foregroundStyle(VuuroColor.textPrimary.opacity(0.85))
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .vuuroCard()
                    }
                }
                .padding()
            }
        }
        .background(VuuroColor.surfaceMuted)
        .navigationTitle("Terms & Privacy")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(VuuroColor.accent)
            }
        }
    }
}