import CoreLocation
import SwiftUI

@MainActor
final class PermissionRequester: ObservableObject {
    static let shared = PermissionRequester()

    private let locationManager = CLLocationManager()
    private var requested = false

    private init() {}

    var isLocationGranted: Bool {
        let status = locationManager.authorizationStatus
        return status == .authorizedWhenInUse || status == .authorizedAlways
    }

    func requestLocationOnce() {
        guard !requested else { return }
        requested = true
        guard locationManager.authorizationStatus == .notDetermined else { return }
        locationManager.requestWhenInUseAuthorization()
    }
}

struct PermissionsView: View {
    let onBack: () -> Void
    let onContinue: () -> Void

    @ObservedObject private var requester = PermissionRequester.shared

    var body: some View {
        VStack(spacing: 0) {
            VuuroNavBar(
                title: "Before you start",
                leading: {
                    VuuroNavButton("Back", icon: "chevron.left", action: onBack)
                },
                trailing: { VuuroNavSpacer() }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VuuroHero(
                        greeting: nil,
                        title: "We need a few permissions",
                        subtitle: "Vuuro Scan works fully offline once you allow these. Nothing is shared until you upload."
                    )

                    VuuroInputGroup {
                        VuuroPermissionRow(
                            icon: "camera.viewfinder",
                            title: "LiDAR & Camera",
                            description: "Required to capture room geometry.",
                            status: "Required",
                            statusStyle: .pending
                        )
                        VuuroPermissionRow(
                            icon: "location",
                            title: "Location (optional)",
                            description: "Tags each scan with GPS for audit trails.",
                            status: requester.isLocationGranted ? "Allowed" : "Optional",
                            statusStyle: requester.isLocationGranted ? .granted : .pending
                        )
                        VuuroPermissionRow(
                            icon: "photo",
                            title: "Photo library",
                            description: "Attach evidence photos to rooms and units.",
                            status: "Optional",
                            statusStyle: .pending,
                            showsDivider: false
                        )
                    }
                    .padding(.horizontal, 20)

                    VStack(spacing: 10) {
                        Button("Allow & continue") {
                            requester.requestLocationOnce()
                            onContinue()
                        }
                        .buttonStyle(.vuuroPrimary)

                        Button("Not now", action: onContinue)
                            .buttonStyle(.vuuroGhostSmall)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                    Spacer().frame(height: 32)
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(VuuroColor.bgApp)
    }
}

struct VuuroPermissionRow: View {
    enum StatusStyle { case pending, granted }

    let icon: String
    let title: String
    let description: String
    let status: String
    let statusStyle: StatusStyle
    var showsDivider: Bool = true

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(VuuroColor.accent)
                .frame(width: 40, height: 40)
                .background(VuuroColor.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(VuuroColor.textPrimary)
                Text(description)
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .foregroundStyle(VuuroColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(status)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.3)
                .textCase(.uppercase)
                .foregroundStyle(statusStyle == .granted ? VuuroColor.lime : VuuroColor.textTertiary)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle().fill(VuuroColor.borderSoft).frame(height: 1)
            }
        }
    }
}