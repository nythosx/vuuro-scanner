import SwiftUI

struct PendingUploadRecoveryView: View {
    let state: PendingUploadState
    let onFinished: (ScanSessionResponse, FloorPlan) -> Void
    let onDiscarded: () -> Void

    @State private var isRetrying = false
    @State private var lastError: AppError?
    @State private var retryTask: Task<Void, Never>?
    @State private var showRetryConfirmation = false

    private static let largeUnitRoomCount = 8

    private let client = ScanServiceClient()

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("An earlier scan upload didn't finish")
                .font(.headline)
            Text("\(state.captures.count) room(s) captured earlier are still on this device and ready to upload. Retry now, or discard them and start over.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            if let lastError {
                ErrorCodeView(error: lastError)
            }

            if isRetrying {
                UploadProgressView(message: "Uploading…", onCancel: { retryTask?.cancel() })
            } else {
                Button("Retry upload") {
                    showRetryConfirmation = true
                }
                .buttonStyle(.borderedProminent)

                Button("Discard", role: .destructive) {
                    DiagnosticsLog.shared.record("Pending upload discarded by user: \(state.captures.count) capture(s), session \(state.session?.id ?? "not yet created")", category: .info)
                    PendingUploadStore.clear()
                    onDiscarded()
                }
            }
        }
        .padding()
        .alert("Retry upload?", isPresented: $showRetryConfirmation) {
            Button("Retry") {
                retryTask = Task { await retry() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(state.captures.count >= Self.largeUnitRoomCount
                ? "This will re-upload all \(state.captures.count) rooms, which may take a while for a unit this size. Make sure you meant to tap this."
                : "This will re-upload \(state.captures.count) room(s) captured earlier.")
        }
        .onAppear {
            DiagnosticsLog.shared.record("Pending upload recovery shown: \(state.captures.count) capture(s), session \(state.session?.id ?? "not yet created")", category: .info)
        }
    }

    @MainActor
    private func retry() async {
        isRetrying = true
        defer { isRetrying = false }
        lastError = nil

        var current = state
        let session: ScanSessionResponse
        if let existing = current.session {
            session = existing
        } else {
            do {
                session = try await client.createSession(identity: current.identity)
            } catch is CancellationError {
                return
            } catch {
                lastError = AppError(site: .sessionCreate, underlying: error)
                return
            }
            current.session = session
            PendingUploadStore.save(current)
            ScanHistoryStore.shared.add(ScanHistoryEntry(
                sessionId: session.id,
                accessToken: session.accessToken,
                propertyId: current.identity.propertyId,
                unitId: current.identity.unitId,
                organisationId: current.identity.organisationId,
                purpose: current.identity.purpose,
                createdAt: Date(),
                expiresAt: session.expiresAt
            ))
        }

        var floorPlan: FloorPlan?
        for capture in current.captures {
            do {
                floorPlan = try await client.uploadCapture(sessionId: session.id, accessToken: session.accessToken, idempotencyKey: capture.idempotencyKey, bodyJSON: capture.bodyJSON)
            } catch is CancellationError {
                return
            } catch {
                lastError = AppError(site: .captureUpload, underlying: error)
                return
            }
        }
        guard let floorPlan else {
            lastError = AppError(site: .captureNoRoom, underlying: nil)
            return
        }
        PendingUploadStore.clear()
        DiagnosticsLog.shared.record("Pending upload recovered successfully: \(current.captures.count) capture(s) into session \(session.id)", category: .info)
        onFinished(session, floorPlan)
    }
}
