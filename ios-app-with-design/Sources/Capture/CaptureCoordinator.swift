//
//  CaptureCoordinator.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see ../Models/ScanIdentity.swift header.
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
        case failed(String)
    }

    @Published private(set) var state: State = .scanning

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
    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        Task { @MainActor in
            if let error {
                self.state = .failed(error.localizedDescription)
                return
            }
            // CapturedRoomData -> CapturedRoom normally goes through
            // RoomBuilder in Apple's sample code. Modeled that way here;
            // unverified against the real SDK signature until this is built
            // in Xcode (see docs/adr/0001-scan-service-stack.md follow-up).
            do {
                let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
                self.capturedRoom = room
                self.state = .finished(roomAvailable: true)
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didFailWith error: Error) {
        Task { @MainActor in
            self.state = .failed(error.localizedDescription)
        }
    }
}
