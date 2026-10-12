import SwiftUI
import UIKit

final class VuuroAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}

enum OrientationLock {
    static var mask: UIInterfaceOrientationMask = .allButUpsideDown

    @MainActor
    static func set(_ newMask: UIInterfaceOrientationMask) {
        mask = newMask
        for case let windowScene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in windowScene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            if newMask == .portrait {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
            }
        }
    }
}

@MainActor
private struct PortraitLockedModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { OrientationLock.set(.portrait) }
            .onDisappear { OrientationLock.set(.allButUpsideDown) }
    }
}

extension View {
    func portraitLocked() -> some View {
        modifier(PortraitLockedModifier())
    }
}
