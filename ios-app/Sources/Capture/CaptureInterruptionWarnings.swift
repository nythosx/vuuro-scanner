import Combine
import SwiftUI
import UIKit

enum CaptureInterruptionText {
    static let screenshot = "Screenshot taken. Swipe the preview away and keep scanning. Opening or sharing it leaves the scan, and the room can stop."
    static let backInScan = "Back in the scan. Go back to where you stood, point the phone at the last part you scanned and move slowly until the lines come back."
    static let longAwaySeconds: TimeInterval = 2
}

struct CaptureInterruptionWarnings: ViewModifier {
    let isScanning: Bool
    @State private var leftAt: Date?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
                guard isScanning else { return }
                DiagnosticsLog.shared.record("Screenshot taken during a scan, warning shown", category: .state)
                VuuroToast.shared.show(vuuroLocalized(CaptureInterruptionText.screenshot), duration: 6)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                leftAt = isScanning ? Date() : nil
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                guard let away = leftAt.map({ Date().timeIntervalSince($0) }) else { return }
                leftAt = nil
                guard isScanning, away >= CaptureInterruptionText.longAwaySeconds else { return }
                DiagnosticsLog.shared.record(String(format: "Back in the scan after %.1f s away, guidance shown", away), category: .state)
                VuuroToast.shared.show(vuuroLocalized(CaptureInterruptionText.backInScan), duration: 6)
            }
    }
}

extension View {
    func captureInterruptionWarnings(isScanning: Bool) -> some View {
        modifier(CaptureInterruptionWarnings(isScanning: isScanning))
    }
}
