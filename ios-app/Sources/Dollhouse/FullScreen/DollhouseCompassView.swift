import SwiftUI

final class DollhouseCompassModel: ObservableObject {
    @Published var degrees: Double = 0
    @Published var headingDeg: Double?
    private var lastYaw: Float?

    func update(yaw: Float) {
        lastYaw = yaw
        guard let headingDeg else { return }
        degrees = DollhouseCamera.compassScreenDegrees(yaw: yaw, headingDeg: headingDeg)
    }

    func setHeading(_ value: Double?) {
        headingDeg = value
        if let lastYaw {
            update(yaw: lastYaw)
        }
    }
}

struct DollhouseCompassView: View {
    @ObservedObject var model: DollhouseCompassModel
    let theme: DollhouseTheme

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
            VStack(spacing: 0) {
                Text("N")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(red: 0.84, green: 0.27, blue: 0.24))
                Capsule()
                    .fill(Color(red: 0.84, green: 0.27, blue: 0.24))
                    .frame(width: 3, height: 9)
                Capsule()
                    .fill(theme == .light ? Color.black.opacity(0.6) : Color.white.opacity(0.7))
                    .frame(width: 3, height: 9)
                Spacer().frame(height: 10)
            }
            .rotationEffect(.degrees(model.degrees))
        }
        .frame(width: 40, height: 40)
        .accessibilityElement()
        .accessibilityLabel(Text("North"))
        .accessibilityIdentifier("dollhouse.compass")
    }
}
