import SwiftUI

struct VuuroCapturePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct VuuroCaptureCircleButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .background(Color.white.opacity(0.10), in: Circle())
        }
        .buttonStyle(VuuroCapturePressStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}

struct VuuroScanRing: View {
    let walls: Int
    var size: CGFloat = 76
    var lineWidth: CGFloat = 5

    private var progress: Double {
        min(Double(walls) / 6.0, 0.95)
    }

    private var percentage: Int {
        Int((progress * 100).rounded())
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(progress, 0.02))
                .stroke(VuuroColor.lime, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.35), value: progress)
            Text("\(percentage)%")
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

struct VuuroScanHint: View {
    let text: String
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(VuuroColor.lime)
                .frame(width: 7, height: 7)
                .shadow(color: VuuroColor.lime, radius: 10)
                .opacity(pulse ? 0.5 : 1)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.1)
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color.black.opacity(0.55), in: Capsule())
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

struct VuuroLiveStat: View {
    let value: String
    let unit: String?
    let label: String

    var body: some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value)
                    .font(.system(size: 17, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(.white)
                if let unit {
                    Text(unit)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
            }
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(Color.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct VuuroLiveStatsRow: View {
    let stats: CaptureLiveStats

    private var heightText: String {
        guard let height = stats.heightM, height > 0 else { return "—" }
        return String(format: "%.1f", height)
    }

    var body: some View {
        HStack(spacing: 10) {
            VuuroLiveStat(value: "\(stats.walls)", unit: nil, label: "Walls")
            VuuroLiveStat(value: String(format: "%.1f", stats.areaM2), unit: "m²", label: "Area")
            VuuroLiveStat(value: heightText, unit: stats.heightM == nil ? nil : "m", label: "Height")
        }
    }
}

struct VuuroCaptureGuessPill: View {
    let typeName: String
    let onConfirm: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("\(typeName)?")
                .font(.system(size: 14, weight: .bold))
                .tracking(-0.2)
                .foregroundStyle(Color(red: 24 / 255, green: 24 / 255, blue: 27 / 255))
                .padding(.leading, 16)
                .padding(.trailing, 6)

            Button(action: onConfirm) {
                Text("✓")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(Color(red: 76 / 255, green: 175 / 255, blue: 80 / 255))
                    .frame(width: 34, height: 34)
                    .background(Color(red: 76 / 255, green: 175 / 255, blue: 80 / 255).opacity(0.15), in: Circle())
            }
            .buttonStyle(VuuroCapturePressStyle())
            .accessibilityLabel("Confirm room type")

            Button(action: onReject) {
                Text("✕")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(Color(red: 229 / 255, green: 57 / 255, blue: 53 / 255))
                    .frame(width: 34, height: 34)
                    .background(Color(red: 229 / 255, green: 57 / 255, blue: 53 / 255).opacity(0.15), in: Circle())
            }
            .buttonStyle(VuuroCapturePressStyle())
            .accessibilityLabel("Correct room type")
        }
        .padding(8)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color.white.opacity(0.97), in: Capsule())
        .shadow(color: .black.opacity(0.4), radius: 32, x: 0, y: 8)
    }
}

struct VuuroCaptureTogglePill: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: isOn ? "wand.and.stars" : "wand.and.stars.inverse")
                    .font(.system(size: 11, weight: .semibold))
                Text(isOn ? "Guessing on" : "Guessing off")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(-0.1)
            }
            .foregroundStyle(isOn ? Color(red: 24 / 255, green: 24 / 255, blue: 27 / 255) : Color.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isOn ? AnyShapeStyle(VuuroColor.lime) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
            .background(isOn ? AnyShapeStyle(Color.clear) : AnyShapeStyle(Color.white.opacity(0.12)), in: Capsule())
        }
        .buttonStyle(VuuroCapturePressStyle())
    }
}

struct VuuroRoomsButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 15, weight: .bold))
                    .tracking(-0.2)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(VuuroCapturePressStyle())
    }
}

struct VuuroFinishRoomButton: View {
    let label: String
    var fixedWidth: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 15, weight: .bold))
                .tracking(-0.2)
                .foregroundStyle(Color(red: 24 / 255, green: 24 / 255, blue: 27 / 255))
                .frame(maxWidth: fixedWidth ? nil : .infinity)
                .padding(.horizontal, fixedWidth ? 16 : 0)
                .padding(.vertical, 15)
                .background(VuuroColor.lime, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: VuuroColor.lime.opacity(0.4), radius: 24, x: 0, y: 8)
        }
        .buttonStyle(VuuroCapturePressStyle())
    }
}

struct VuuroFinishSecondaryButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 15, weight: .bold))
                .tracking(-0.2)
                .foregroundStyle(Color(red: 24 / 255, green: 24 / 255, blue: 27 / 255))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(VuuroColor.lime, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(VuuroCapturePressStyle())
    }
}

struct VuuroCaptureDiskBackground: View {
    var body: some View {
        Color.black
            .overlay(
                ZStack {
                    RadialGradient(
                        colors: [Color(red: 175 / 255, green: 223 / 255, blue: 37 / 255).opacity(0.13), .clear],
                        center: UnitPoint(x: 0.30, y: 0.25),
                        startRadius: 0,
                        endRadius: 320
                    )
                    RadialGradient(
                        colors: [Color(red: 46 / 255, green: 195 / 255, blue: 255 / 255).opacity(0.10), .clear],
                        center: UnitPoint(x: 0.72, y: 0.68),
                        startRadius: 0,
                        endRadius: 320
                    )
                    LinearGradient(
                        colors: [
                            Color(red: 26 / 255, green: 26 / 255, blue: 30 / 255),
                            Color(red: 10 / 255, green: 10 / 255, blue: 12 / 255),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            )
            .ignoresSafeArea()
    }
}