import SwiftUI

struct ReagreeTermsView: View {
    var onAgree: () -> Void
    var onDecline: () -> Void

    var body: some View {
        TermsAndPrivacyView()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Decline", role: .cancel, action: onDecline)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("I Agree", action: onAgree)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("The Terms of Service or Privacy Policy have changed since you last agreed. Review them and tap \"I Agree\" to continue scanning.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.thinMaterial)
            }
    }
}