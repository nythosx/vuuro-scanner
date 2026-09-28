
import RoomPlan
import SwiftUI

struct RoomCaptureScreen: UIViewRepresentable {
    let coordinator: CaptureCoordinator

    func makeUIView(context: Context) -> RoomCaptureHostView {
        let host = RoomCaptureHostView()
        host.onWindowChange = { [weak coordinator] in coordinator?.captureViewWindowDidChange() }
        host.onDismantle = { coordinator.tearDownIfDetached() }
        host.embed(coordinator.captureView)
        return host
    }

    func updateUIView(_ uiView: RoomCaptureHostView, context: Context) {
        uiView.embed(coordinator.captureView)
    }

    static func dismantleUIView(_ uiView: RoomCaptureHostView, coordinator: ()) {
        uiView.dismantle()
    }
}

final class RoomCaptureHostView: UIView {
    var onWindowChange: (@MainActor () -> Void)?
    var onDismantle: (@MainActor () -> Void)?

    func embed(_ view: UIView) {
        guard view.superview !== self else { return }
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(view)
        onWindowChange?()
    }

    func dismantle() {
        let onDismantle = onDismantle
        Task { @MainActor in
            onDismantle?()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
    }
}

final class RoomCaptureScreenViewDelegate: NSObject, RoomCaptureViewDelegate {
    override init() {
        super.init()
    }

    init?(coder: NSCoder) {
        super.init()
    }

    func encode(with coder: NSCoder) {
    }

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        false
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
    }
}
