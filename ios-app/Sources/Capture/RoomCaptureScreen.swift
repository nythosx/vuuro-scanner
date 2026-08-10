//
//  RoomCaptureScreen.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see ../Models/ScanIdentity.swift header.
//

import RoomPlan
import SwiftUI

/// SwiftUI wrapper around RoomPlan's UIKit `RoomCaptureView`. RoomPlan does
/// not ship a SwiftUI-native capture view as of this writing, so bridging
/// via UIViewRepresentable is the documented approach — confirm this is
/// still true once Xcode/current RoomPlan docs are reachable.
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

    func makeCoordinator() -> ViewDelegate {
        ViewDelegate()
    }

    /// Separate from CaptureCoordinator on purpose: RoomCaptureViewDelegate
    /// governs whether/how RoomPlan's own results UI presents, which is a
    /// different concern from owning session lifecycle + export.
    final class ViewDelegate: NSObject, RoomCaptureViewDelegate {
        func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
            error == nil
        }

        func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
            // Intentionally empty: CaptureCoordinator.captureSession(_:didEndWith:error:)
            // is the single source of truth for the finished CapturedRoom,
            // so this delegate method doesn't duplicate that state.
        }
    }
}
