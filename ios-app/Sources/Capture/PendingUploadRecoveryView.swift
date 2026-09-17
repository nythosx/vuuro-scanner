import SwiftUI

struct PendingUploadRecoveryView: View {
    let onFinished: (ScanSessionResponse, FloorPlan) -> Void
    let onDiscarded: () -> Void
    let onSkipped: () -> Void

    @State private var currentState: PendingUploadState
    @State private var isRetrying = false
    @State private var lastError: AppError?
    @State private var retryTask: Task<Void, Never>?
    @State private var showRetryConfirmation = false

    private static let largeUnitRoomCount = 8

    private let client = ScanServiceClient()

    init(state: PendingUploadState, onFinished: @escaping (ScanSessionResponse, FloorPlan) -> Void, onDiscarded: @escaping () -> Void, onSkipped: @escaping () -> Void) {
        _currentState = State(initialValue: state)
        self.onFinished = onFinished
        self.onDiscarded = onDiscarded
        self.onSkipped = onSkipped
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("An earlier scan upload didn't finish")
                .font(.headline)
            Text("\(currentState.captures.count) room(s) captured earlier are still on this device and ready to upload. Retry now, or discard them and start over.")
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

                Button("Skip for now") {
                    onSkipped()
                }
                .buttonStyle(.bordered)

                Button("Discard", role: .destructive) {
                    DiagnosticsLog.shared.record("Pending upload discarded by user: \(currentState.captures.count) capture(s), session \(currentState.session?.id ?? "not yet created")", category: .info)
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
            Text(currentState.captures.count >= Self.largeUnitRoomCount
                ? "This will re-upload all \(currentState.captures.count) rooms, which may take a while for a unit this size. Make sure you meant to tap this."
                : "This will re-upload \(currentState.captures.count) room(s) captured earlier.")
        }
        .onAppear {
            DiagnosticsLog.shared.record("Pending upload recovery shown: \(currentState.captures.count) capture(s), session \(currentState.session?.id ?? "not yet created")", category: .info)
        }
        .onDisappear {
            retryTask?.cancel()
        }
    }

    @MainActor
    private func retry() async {
        isRetrying = true
        defer { isRetrying = false }
        lastError = nil

        let session: ScanSessionResponse
        if let existing = currentState.session {
            session = existing
        } else {
            do {
                session = try await client.createSession(identity: currentState.identity)
            } catch is CancellationError {
                return
            } catch {
                lastError = AppError(site: .sessionCreate, underlying: error)
                return
            }
            currentState.session = session
            PendingUploadStore.save(currentState)
            ScanHistoryStore.shared.add(ScanHistoryEntry(
                sessionId: session.id,
                accessToken: session.accessToken,
                propertyId: currentState.identity.propertyId,
                unitId: currentState.identity.unitId,
                organisationId: currentState.identity.organisationId,
                purpose: currentState.identity.purpose,
                createdAt: Date(),
                expiresAt: session.expiresAt,
                occupied: currentState.identity.occupied,
                consentObtained: currentState.identity.consentObtained
            ))
        }

        guard !currentState.captures.isEmpty else {
            lastError = AppError(site: .captureNoRoom, underlying: nil)
            return
        }

        while let capture = currentState.captures.first {
            let floorPlan: FloorPlan
            do {
                floorPlan = try await client.uploadCapture(sessionId: session.id, accessToken: session.accessToken, idempotencyKey: capture.idempotencyKey, bodyJSON: capture.bodyJSON)
            } catch is CancellationError {
                return
            } catch {
                lastError = AppError(site: .captureUpload, underlying: error)
                return
            }
            currentState.captures.removeFirst()
            PendingUploadStore.save(currentState)
            if currentState.captures.isEmpty {
                PendingUploadStore.clear()
                DiagnosticsLog.shared.record("Pending upload recovered successfully into session \(session.id)", category: .info)
                onFinished(session, floorPlan)
                return
            }
        }
    }
}
