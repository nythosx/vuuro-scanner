import RoomPlan
import SwiftUI

struct MultiRoomCaptureScreen: UIViewRepresentable {
    let coordinator: MultiRoomCaptureCoordinator

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero, arSession: coordinator.arSession)
        coordinator.attach(to: view.captureSession)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {
    }

    func makeCoordinator() -> RoomCaptureScreenViewDelegate {
        RoomCaptureScreenViewDelegate()
    }
}
