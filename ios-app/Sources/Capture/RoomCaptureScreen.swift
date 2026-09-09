
import RoomPlan
import SwiftUI

struct RoomCaptureScreen: UIViewRepresentable {
    let coordinator: CaptureCoordinator

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
