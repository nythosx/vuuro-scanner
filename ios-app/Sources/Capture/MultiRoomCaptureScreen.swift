import RoomPlan
import SwiftUI

struct MultiRoomCaptureScreen: UIViewRepresentable {
    let coordinator: MultiRoomCaptureCoordinator
    var liveMesh = false

    func makeUIView(context: Context) -> RoomCaptureHostView {
        let host = RoomCaptureHostView()
        host.onWindowChange = { [weak coordinator] in coordinator?.captureViewWindowDidChange() }
        host.onDismantle = { coordinator.tearDownIfDetached() }
        host.embed(coordinator.captureView)
        return host
    }

    func updateUIView(_ uiView: RoomCaptureHostView, context: Context) {
        uiView.embed(coordinator.captureView)
        uiView.setLiveMesh(liveMesh, session: coordinator.arSession)
    }

    static func dismantleUIView(_ uiView: RoomCaptureHostView, coordinator: ()) {
        uiView.dismantle()
    }
}
