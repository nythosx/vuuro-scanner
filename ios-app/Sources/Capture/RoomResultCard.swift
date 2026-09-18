import SwiftUI

struct RoomResultCard: View {
    let room: FloorPlan.Room
    var showsRibbon: Bool = false
    var isFused: Bool = false
    let photos: [FloorPlan.Photo]
    let notes: [FloorPlan.Note]
    let session: ScanSessionResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            metrics
            VuuroQualityBar(score: room.coverage.score)
            if !photos.isEmpty || !notes.isEmpty {
                attachments
            }
            disclaimer
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VuuroColor.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: VuuroMetrics.cardShadowTightColor, radius: VuuroMetrics.cardShadowTightRadius, x: 0, y: 1)
        .shadow(color: VuuroMetrics.cardShadowColor, radius: VuuroMetrics.cardShadowRadius, x: 0, y: 4)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(room.label)
                        .font(.system(size: 18, weight: .bold))
                        .tracking(-0.3)
                        .foregroundStyle(VuuroColor.textPrimary)
                    if showsRibbon {
                        VuuroRibbon(text: "FUSED")
                    }
                }
                if let subtitle = subtitleText {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(VuuroColor.textSecondary)
                }
            }
            Spacer(minLength: 0)
            badge
        }
    }

    private var subtitleText: String? {
        if let confirmed = room.roomType?.confirmed, !confirmed.isEmpty {
            return RoomTypeClassifier.displayName(for: confirmed)
        }
        if let guess = room.roomType?.guess, !guess.isEmpty {
            return "\(RoomTypeClassifier.displayName(for: guess)) (suggested)"
        }
        return nil
    }

    @ViewBuilder
    private var badge: some View {
        if room.coverage.score < 80 || room.confidence.lowercased() == "low" {
            VuuroBadge("Low confidence", systemImage: "exclamationmark.triangle.fill", style: .warning)
        } else if let confirmed = room.roomType?.confirmed, !confirmed.isEmpty {
            VuuroBadge(RoomTypeClassifier.displayName(for: confirmed), style: .info)
        } else {
            VuuroBadge("Captured", style: .good)
        }
    }

    private var metrics: some View {
        VuuroRoomMetricGrid(items: [
            .init(value: String(format: "%.1f", room.floorAreaM2), unit: "m²", label: "Area"),
            .init(value: String(format: "%.1f", room.perimeterM), unit: "m", label: "Perimeter"),
            .init(value: heightText, unit: room.heightM == nil ? nil : "m", label: "Height"),
        ])
    }

    private var heightText: String {
        guard let height = room.heightM, height > 0 else { return "—" }
        return String(format: "%.1f", height)
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().background(VuuroColor.borderSoft)
            RoomAttachmentsList(session: session, photos: photos, notes: notes)
        }
    }

    private var disclaimer: some View {
        Text("Indicative. NEN2580-inspired, not certified.")
            .font(.system(size: 11))
            .foregroundStyle(VuuroColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
            .overlay(alignment: .top) {
                Rectangle().fill(VuuroColor.borderSoft).frame(height: 1)
            }
    }
}