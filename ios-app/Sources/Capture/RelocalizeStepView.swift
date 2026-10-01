import SwiftUI

struct RelocalizeStepView: View {
    enum Status: Equatable {
        case looking
        case recognised
        case timedOut
        case unavailable
    }

    let status: Status
    let secondsRemaining: Int
    let onSkip: () -> Void
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: status == .recognised ? "checkmark.circle.fill" : "viewfinder")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(status == .recognised ? VuuroColor.lime : .white)
                Text(LocalizedStringKey(titleText))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(LocalizedStringKey(messageText))
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                if status == .looking {
                    Text(String(format: vuuroLocalized("Looking… %llds"), secondsRemaining))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                VStack(spacing: 10) {
                    if status == .timedOut || status == .unavailable {
                        Button(vuuroLocalized("Try again"), action: onRetry)
                            .accessibilityIdentifier("relocalize.retry")
                            .buttonStyle(.vuuroPrimary)
                        Button(vuuroLocalized("Skip and place by hand later"), action: onSkip)
                            .accessibilityIdentifier("relocalize.skip")
                            .buttonStyle(.vuuroGhostSmall)
                    } else if status == .recognised {
                        ProgressView().tint(.white)
                    } else {
                        Button(vuuroLocalized("Skip and place by hand later"), action: onSkip)
                            .accessibilityIdentifier("relocalize.skip")
                            .buttonStyle(.vuuroGhostSmall)
                    }
                }
                .padding(.top, 8)
                .frame(maxWidth: 320)
            }
            .padding(24)
        }
    }

    private var titleText: String {
        switch status {
        case .looking: return vuuroLocalized("Looking for the scanned rooms…")
        case .recognised: return vuuroLocalized("Recognised ✓")
        case .timedOut: return vuuroLocalized("Couldn't recognise the rooms")
        case .unavailable: return vuuroLocalized("Recognition not available")
        }
    }

    private var messageText: String {
        switch status {
        case .looking:
            return vuuroLocalized("Start in a room you already scanned. Move slowly along the walls. Use the same lights as the first scan.")
        case .recognised:
            return vuuroLocalized("Starting the scan now.")
        case .timedOut:
            return vuuroLocalized("You can try again, or scan anyway and place the new rooms by hand.")
        case .unavailable:
            return vuuroLocalized("This phone can't recognise the earlier scan. New rooms will be added as their own section and you can place them by hand.")
        }
    }
}
