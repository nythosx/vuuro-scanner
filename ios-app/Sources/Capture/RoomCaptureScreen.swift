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
        // RoomCaptureView.captureSession is get-only — the view creates and
        // owns its own session, so we attach to it rather than assigning one.
        coordinator.attach(to: view.captureSession)
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

    // Real bug found on this pass: this returned `true`, which tells
    // RoomCaptureView to present Apple's own post-scan review/edit screen —
    // but CaptureCoordinator.captureSession(_:didEndWith:error:) already
    // builds the CapturedRoom and kicks off the upload the instant capture
    // ends, before that review screen is even shown. A user editing walls
    // in the review UI and tapping Done would have their edits silently
    // discarded — the (pre-edit) upload already happened, or was already in
    // flight, using stale data. Returning `false` here skips that
    // never-actually-authoritative review screen entirely, so there's only
    // ever one path to a submitted room, matching what didPresent's
    // (now-removed) empty-stub comment already claimed was true.
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        false
    }

    // Still a required protocol member even though returning `false` above
    // means RoomCaptureView should never actually call it. No state to
    // capture if it somehow does.
    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
    }
}
