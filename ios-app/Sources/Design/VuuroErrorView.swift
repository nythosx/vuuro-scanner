import SwiftUI
import UIKit

struct ErrorView: View {
    let error: AppError
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VuuroNavBar(
                title: "Error",
                leading: { VuuroNavSpacer() },
                trailing: {
                    Button("Done", action: onRetry)
                        .accessibilityIdentifier("error.done")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(VuuroColor.accent)
                }
            )

            VuuroCenterView {
                VuuroIconBadge(
                    systemName: "exclamationmark.circle",
                    tint: VuuroColor.danger,
                    background: VuuroColor.dangerTint
                )

                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(VuuroColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .foregroundStyle(VuuroColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)

                errorCodeCard

                Button("Try again", action: onRetry)
                    .accessibilityIdentifier("error.tryAgain")
                    .buttonStyle(.vuuroPrimary)
                    .padding(.top, 8)
                    .frame(maxWidth: 320)
            }
        }
        .background(VuuroColor.bgApp)
    }

    private var title: String {
        if isTransportError {
            return "Couldn't reach the server"
        }
        return "Something went wrong"
    }

    private var subtitle: String {
        if isTransportError {
            return "Check your connection and try again."
        }
        return error.userMessage
    }

    private var isTransportError: Bool {
        guard let scanError = error.underlying as? ScanServiceError else { return false }
        if case .transport = scanError { return true }
        return false
    }

    private var errorCodeCard: some View {
        HStack(spacing: 10) {
            Text(displayCode)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(VuuroColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button {
                UIPasteboard.general.string = error.copyableDetails
                VuuroToast.shared.show("Copied")
            } label: {
                Text("Copy")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VuuroColor.accent)
            }
            .accessibilityIdentifier("error.action")
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 340, alignment: .leading)
        .background(VuuroColor.bgCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: VuuroMetrics.cardShadowTightColor, radius: VuuroMetrics.cardShadowTightRadius, x: 0, y: 1)
        .shadow(color: VuuroMetrics.cardShadowColor, radius: VuuroMetrics.cardShadowRadius, x: 0, y: 4)
    }

    private var displayCode: String {
        if !error.code.isEmpty { return error.code }
        return "VS-\(error.site.rawValue)"
    }
}