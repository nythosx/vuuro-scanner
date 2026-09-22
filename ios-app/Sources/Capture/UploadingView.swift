import SwiftUI

struct UploadingView: View {
    @ObservedObject var coordinator: UploadProgressCoordinator
    let onPause: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VuuroNavBar(
                title: "Uploading",
                leading: { VuuroNavSpacer() },
                trailing: { VuuroNavSpacer() }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VuuroHero(
                        greeting: nil,
                        title: "Uploading your unit",
                        subtitle: progressSubtitle
                    )

                    VuuroQualityBar(score: Int((coordinator.overallProgress * 100).rounded()))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)

                    if coordinator.rows.isEmpty {
                        ProgressView()
                            .tint(VuuroColor.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(coordinator.rows) { row in
                                UploadProgressRow(row: row)
                            }
                        }
                        .padding(.horizontal, 16)
                        .background(VuuroColor.bgCard)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: VuuroMetrics.cardShadowTightColor, radius: VuuroMetrics.cardShadowTightRadius, x: 0, y: 1)
                        .shadow(color: VuuroMetrics.cardShadowColor, radius: VuuroMetrics.cardShadowRadius, x: 0, y: 4)
                        .padding(.horizontal, 20)
                    }

                    Button("Cancel upload", action: onPause)
                        .buttonStyle(.vuuroGhostSmall)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)

                    Spacer().frame(height: 24)
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(VuuroColor.bgApp)
    }

    private var progressSubtitle: String {
        let total = coordinator.totalRooms
        let completed = coordinator.completedRooms
        guard total > 0 else { return "Preparing to upload. Keep the app open." }
        return "\(completed) of \(total) room\(total == 1 ? "" : "s") uploaded. Keep the app open."
    }
}

private struct UploadProgressRow: View {
    let row: VuuroUploadRow

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(VuuroColor.textPrimary)
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(statusColor)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(VuuroColor.borderSoft).frame(height: 1)
        }
    }

    @ViewBuilder
    private var icon: some View {
        ZStack {
            Circle().fill(iconBackground)
            switch row.state {
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(Color(red: 24 / 255, green: 24 / 255, blue: 27 / 255))
            case .uploading:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VuuroColor.accent)
            case .failed:
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(VuuroColor.danger)
            case .pending:
                Image(systemName: "circle")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(VuuroColor.textTertiary)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var iconBackground: Color {
        switch row.state {
        case .done: return VuuroColor.lime
        case .uploading: return VuuroColor.accent.opacity(0.15)
        case .failed: return VuuroColor.danger.opacity(0.14)
        case .pending: return VuuroColor.bgInset
        }
    }

    private var statusText: String {
        switch row.state {
        case .pending: return "Waiting"
        case .uploading: return "Uploading…"
        case .failed: return "Failed"
        case .done(let areaM2):
            if let areaM2, areaM2 > 0 {
                return "Uploaded · \(String(format: "%.1f", areaM2)) m²"
            }
            return "Uploaded"
        }
    }

    private var statusColor: Color {
        switch row.state {
        case .done: return VuuroColor.goodText
        case .uploading: return VuuroColor.accent
        case .failed: return VuuroColor.danger
        case .pending: return VuuroColor.textSecondary
        }
    }
}