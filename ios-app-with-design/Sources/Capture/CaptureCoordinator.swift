//
//  CaptureCoordinator.swift
//  VuuroScan
//
//  This branch had fallen behind ios-app/'s logic: stop(), the removal of
//  the dead didFailWith method, and the partial-capture-recovery branch
//  below were ported over from there (2026-09) — see ARCHITECTURE.md's
//  business-logic-drift note and ios-app/'s copy of this file for the
//  real-device verification history behind these changes.
//
//  Owns one RoomPlan capture session end to end and hands the finished
//  CapturedRoom to the exporter/network layer. Deliberately holds nothing
//  about Vuuro identity — that's threaded through by the caller — so this
//  class stays a pure RoomPlan wrapper, keeping "the scanner is a
//  pluggable provider, not the product" true on the client side too,
//  matching the provider-neutral adapter boundary on the service side
//  (RoomPlanSimulatorAdapter).
//

import Combine
import RoomPlan

@MainActor
final class CaptureCoordinator: NSObject, ObservableObject {
    enum State: Equatable {
        case scanning
        case finished(roomAvailable: Bool)
        // partialRoomAvailable distinguishes "RoomBuilder still reconstructed
        // something from what was captured before the error" from "genuinely
        // nothing to salvage" — see didEndWith below for why this is knowable
        // at all.
        case failed(String, partialRoomAvailable: Bool)
    }

    // didSet, not a wrapper around every assignment site, so no future state
    // change can silently skip logging. Ported from ios-app/'s copy.
    @Published private(set) var state: State = .scanning {
        didSet {
            DiagnosticsLog.shared.record("Capture state -> \(state)", category: .state)
        }
    }

    private(set) var capturedRoom: CapturedRoom?

    /// RoomCaptureView.captureSession is get-only — confirmed live via the
    /// GitHub Actions simulator compile-check — so this class can't own its
    /// own RoomCaptureSession the way this file originally assumed. Instead
    /// RoomCaptureScreen.makeUIView hands over the view's own session here
    /// once the view exists.
    private var captureSession: RoomCaptureSession?

    func attach(to session: RoomCaptureSession) {
        captureSession = session
        session.delegate = self
    }

    func start() {
        guard let captureSession else { return }
        state = .scanning
        // RoomCaptureSession.Configuration() with defaults matches Apple's
        // documented single-room guided capture. Multi-room stitching
        // (Phase 2) needs a real look at RoomCaptureSession's multi-room
        // support once Xcode access exists — not assumed here.
        let configuration = RoomCaptureSession.Configuration()
        captureSession.run(configuration: configuration)
    }

    func stop() {
        captureSession?.stop()
    }
}

extension CaptureCoordinator: RoomCaptureSessionDelegate {
    // RoomCaptureSessionDelegate has exactly one session-end callback —
    // didEndWith(data:error:), confirmed against Apple's own docs/forums.
    // There is no separate didFailWith(error:)-style member: this file
    // previously declared one anyway, which compiled cleanly (an extension
    // can always add extra methods) but RoomCaptureSession itself never
    // calls anything but didEndWith, on success AND on a fatal error like
    // CaptureError.worldTrackingFailure — so that method was dead code that
    // never actually ran, removed here (see ios-app/'s copy of this file for
    // the full source citations).
    //
    // The real, verified consequence: `data` is still delivered alongside a
    // non-nil `error`, so a world-tracking failure does not by itself mean
    // nothing was captured. Always attempting RoomBuilder, rather than
    // returning early on `error != nil`, is what actually answers "is there
    // a sensible 'use what was captured' option."
    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        Task { @MainActor in
            // CapturedRoomData -> CapturedRoom normally goes through
            // RoomBuilder in Apple's sample code. Modeled that way here;
            // unverified against the real SDK signature until this is built
            // in Xcode (see docs/adr/0001-scan-service-stack.md follow-up).
            do {
                let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
                self.capturedRoom = room
                if let error {
                    // RoomBuilder not throwing doesn't mean there's anything
                    // worth offering — a near-instant failure can still
                    // produce a technically-valid but empty room. Only call
                    // it a real partial capture if it actually has geometry.
                    let hasUsableGeometry = !room.walls.isEmpty || !room.floors.isEmpty
                    self.state = .failed(error.localizedDescription, partialRoomAvailable: hasUsableGeometry)
                } else {
                    self.state = .finished(roomAvailable: true)
                }
            } catch {
                self.state = .failed(error.localizedDescription, partialRoomAvailable: false)
            }
        }
    }

    // RoomPlan's own real-time guidance — logged so a report comes with what
    // RoomPlan was telling the tester right before a failure, not just the
    // final error. Ported from ios-app/'s copy of this file.
    nonisolated func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        Task { @MainActor in
            DiagnosticsLog.shared.record("RoomPlan instruction: \(instruction)", category: .instruction)
        }
    }
}
