//
//  CaptureCoordinator.swift
//  VuuroScan
//
//  Real-device confirmed through Mark's 2026-09-01 test (feature/vuuro-scan
//  @ a3c6284): start()/attach() and the didEndWith error path both ran for
//  real (a genuine ARKit CaptureError.worldTrackingFailure). stop() and the
//  partial-capture-recovery branch added after that test are compiled-via-CI
//  only so far — not yet run on real hardware. See
//  ../Models/ScanIdentity.swift header for what that distinction means
//  generally.
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
    // change can silently skip logging.
    @Published private(set) var state: State = .scanning {
        didSet {
            #if DEBUG
            DiagnosticsLog.shared.record("Capture state -> \(state)", category: .state)
            #endif
        }
    }

    private(set) var capturedRoom: CapturedRoom?

    @Published private(set) var isApproachingSizeLimit = false {
        didSet {
            guard oldValue != isApproachingSizeLimit else { return }
            #if DEBUG
            DiagnosticsLog.shared.record("Room size warning -> \(isApproachingSizeLimit)", category: .state)
            #endif
        }
    }

    @Published private(set) var liveRoomTypeGuess: RoomTypeClassifier.Guess?
    private(set) var roomTypeConfirmation: String?
    private(set) var roomTypeConfirmedForGuessType: String?

    var roomTypeConfirmationForExport: RoomTypeConfirmation? {
        roomTypeConfirmation.map { RoomTypeConfirmation(value: $0, answeredForGuessType: roomTypeConfirmedForGuessType) }
    }

    func confirmRoomTypeGuess() {
        roomTypeConfirmation = liveRoomTypeGuess?.type
        roomTypeConfirmedForGuessType = liveRoomTypeGuess?.type
        #if DEBUG
        DiagnosticsLog.shared.record("Room type confirmed: \(liveRoomTypeGuess?.type ?? "nil")", category: .info)
        #endif
    }

    func rejectRoomTypeGuess(correctedTo type: String?) {
        roomTypeConfirmation = type
        roomTypeConfirmedForGuessType = liveRoomTypeGuess?.type
        #if DEBUG
        DiagnosticsLog.shared.record("Room type corrected: guess=\(liveRoomTypeGuess?.type ?? "nil") -> \(type ?? "nil")", category: .info)
        #endif
    }

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
        liveRoomTypeGuess = nil
        roomTypeConfirmation = nil
        roomTypeConfirmedForGuessType = nil
        isApproachingSizeLimit = false
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
    // didEndWith(data:error:) — confirmed against Apple's own docs/forums
    // (developer.apple.com/documentation/roomplan/roomcapturesessiondelegate;
    // forum thread 726971 lists the full method set). There is no separate
    // didFailWith(error:)-style member: this file previously declared one
    // anyway, which compiled cleanly (an extension can always add extra
    // methods) but RoomCaptureSession itself never calls anything but
    // didEndWith, on success AND on a fatal error like
    // CaptureError.worldTrackingFailure — so that method was dead code that
    // never actually ran, removed here.
    //
    // The real, verified consequence: `data` is still delivered alongside a
    // non-nil `error` (Apple's own error-handling example does the same —
    // stores the error without ever discarding `data`), so a world-tracking
    // failure does not by itself mean nothing was captured. Always
    // attempting RoomBuilder, rather than returning early on `error != nil`,
    // is what actually answers "is there a sensible 'use what was captured'
    // option": if RoomBuilder can still reconstruct a room from the partial
    // data, there is one; if RoomBuilder itself throws, there genuinely
    // isn't, and discard-and-retry is the honest answer.
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

    // RoomPlan's own real-time guidance (e.g. "move closer to a wall",
    // "turn on more light") — logged so a report like Mark's world-tracking
    // failure comes with what RoomPlan was actually telling him right before
    // it happened, not just the final error with no lead-up.
    nonisolated func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        #if DEBUG
        Task { @MainActor in
            DiagnosticsLog.shared.record("RoomPlan instruction: \(instruction)", category: .instruction)
        }
        #endif
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        let exceedsSizeLimit = RoomSizeGuard.exceedsPracticalLimit(room)
        Task { @MainActor in
            self.isApproachingSizeLimit = exceedsSizeLimit
        }
        guard RoomTypeGuessSettings.isEnabled, let guess = RoomTypeClassifier.guess(for: room) else { return }
        Task { @MainActor in
            if self.liveRoomTypeGuess?.type != guess.type {
                self.liveRoomTypeGuess = guess
            }
        }
    }
}
