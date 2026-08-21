//
//  RoomCaptureScreen.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see ../Models/ScanIdentity.swift header.
//

import RoomPlan
import SwiftUI

struct RoomCaptureScreen: UIViewRepresentable {
    let coordinator: CaptureCoordinator

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        view.captureSession = coordinator.captureSession
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {
        // No dynamic properties to push down yet — capture state lives on
        // CaptureCoordinator, observed by the SwiftUI parent, not here.
    }

    func makeCoordinator() -> RoomCaptureScreenViewDelegate {
        RoomCaptureScreenViewDelegate()
    }
}

/// Separate from CaptureCoordinator on purpose: RoomCaptureViewDelegate
/// governs whether/how RoomPlan's own results UI presents, which is a
/// different concern from owning session lifecycle + export.
///
/// Confirmed live via the GitHub Actions simulator compile-check (Xcode
/// 16.4): an NSObject conforming to RoomCaptureViewDelegate is required by
/// the compiler to also satisfy NSCoding, even though RoomCaptureViewDelegate
/// itself declares no such requirement — moving this class to top-level (out
/// of RoomCaptureScreen) did not change the diagnostic, so it isn't a
/// nested-type mangled-name artifact. The two stub members below are exactly
/// what the compiler's own "add stubs for conformance" note asks for; this
/// delegate has no state to (de)serialize, so both are no-ops.
final class RoomCaptureScreenViewDelegate: NSObject, RoomCaptureViewDelegate {
    override init() {
        super.init()
    }

    init?(coder: NSCoder) {
        super.init()
    }

    func encode(with coder: NSCoder) {
        // No archivable state — see class-level comment.
    }

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        error == nil
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        // Intentionally empty: CaptureCoordinator.captureSession(_:didEndWith:error:)
        // is the single source of truth for the finished CapturedRoom,
        // so this delegate method doesn't duplicate that state.
    }
}
