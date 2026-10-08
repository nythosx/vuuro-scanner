import SwiftUI

struct DollhousePlaceholderView: View {
    enum Kind {
        case empty
        case loading
        case error(String)
    }

    let kind: Kind
    var onShowPlan: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            switch kind {
            case .loading:
                ProgressView().tint(VuuroColor.accent)
                Text("Building 3D view…")
                    .font(.system(size: 13))
                    .foregroundStyle(VuuroColor.textSecondary)
            case .empty:
                VuuroIconBadge(systemName: "cube.transparent", tint: VuuroColor.textSecondary, background: VuuroColor.bgInset)
                Text("No rooms to show in 3D")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VuuroColor.textPrimary)
                Text("This scan has no captured room geometry. The 2D plan and PDF are still available.")
                    .font(.system(size: 13))
                    .foregroundStyle(VuuroColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                if let onShowPlan {
                    Button("Show 2D plan", action: onShowPlan)
                        .accessibilityIdentifier("dollhouse.showPlan")
                        .buttonStyle(.vuuroGhostSmall)
                        .frame(maxWidth: 200)
                        .padding(.top, 4)
                }
            case .error(let message):
                VuuroIconBadge(systemName: "exclamationmark.triangle", tint: VuuroColor.danger, background: VuuroColor.dangerTint)
                Text("Couldn't build the 3D view")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VuuroColor.textPrimary)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(VuuroColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                if let onShowPlan {
                    Button("Show 2D plan", action: onShowPlan)
                        .accessibilityIdentifier("dollhouse.showPlanFallback")
                        .buttonStyle(.vuuroGhostSmall)
                        .frame(maxWidth: 200)
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(20)
        .background(VuuroColor.bgInset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
