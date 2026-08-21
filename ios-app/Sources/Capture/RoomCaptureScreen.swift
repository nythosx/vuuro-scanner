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
/// Deliberately top-level, not nested inside RoomCaptureScreen: a class
/// nested inside a struct gets a compiler-mangled Objective-C name
/// (_TtCV...) that trips an NSCoding-conformance diagnostic against
/// RoomCaptureViewDelegate under Xcode 16's Swift compiler, even though
/// the protocol never requires NSCoding.
final class RoomCaptureScreenViewDelegate: NSObject, RoomCaptureViewDelegate {
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        error == nil
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        // Intentionally empty: CaptureCoordinator.captureSession(_:didEndWith:error:)
        // is the single source of truth for the finished CapturedRoom,
        // so this delegate method doesn't duplicate that state.
    }
}
