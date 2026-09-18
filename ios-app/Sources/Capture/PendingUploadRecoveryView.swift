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

    init(
        state: PendingUploadState,
        onFinished: @escaping (ScanSessionResponse, FloorPlan) -> Void,
        onDiscarded: @escaping () -> Void,
        onSkipped: @escaping () -> Void
    ) {
        _currentState = State(initialValue: state)
        self.onFinished = onFinished
        self.onDiscarded = onDiscarded
        self.onSkipped = onSkipped
    }

    var body: some View {
        VStack(spacing: 0) {
            VuuroNavBar(
                title: "Pending upload",
                leading: { VuuroNavSpacer() },
                trailing: { VuuroNavSpacer() }
            )

            VuuroCenterView {
                VuuroIconBadge(
                    systemName: "arrow.triangle.2.circlepath",
                    tint: VuuroColor.accent,
                    background: VuuroColor.accent.opacity(0.15)
                )

                Text("An earlier upload didn't finish")
                    .font(.system(size: 20, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(VuuroColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .foregroundStyle(VuuroColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)

                if let lastError {
                    ErrorCodeView(error: lastError)
                        .frame(maxWidth: 320)
                }

                if isRetrying {
                    ProgressView()
                        .tint(VuuroColor.accent)
                        .padding(.top, 16)
                } else {
                    VStack(spacing: 10) {
                        Button("Retry upload") {
                            showRetryConfirmation = true
                        }
                        .buttonStyle(.vuuroPrimary)

                        Button("Skip for now", action: onSkipped)
                            .buttonStyle(.vuuroGhostSmall)

                        Button("Discard pending") {
                            DiagnosticsLog.shared.record(
                                "Pending upload discarded by user: \(currentState.captures.count) capture(s), session \(currentState.session?.id ?? "not yet created")",
                                category: .info
                            )
                            PendingUploadStore.clear()
                            onDiscarded()
                        }
                        .buttonStyle(.vuuroDestructiveSmall)
                    }
                    .padding(.top, 24)
                    .frame(maxWidth: 320)
                }
            }
        }
        .background(VuuroColor.bgApp)
        .alert("Retry upload?", isPresented: $showRetryConfirmation) {
            Button("Retry") {
                retryTask?.cancel()
                retryTask = Task { await retry() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(retryConfirmationMessage)
        }
        .onAppear {
            DiagnosticsLog.shared.record(
                "Pending upload recovery shown: \(currentState.captures.count) capture(s), session \(currentState.session?.id ?? "not yet created")",
                category: .info
            )
        }
        .onDisappear {
            retryTask?.cancel()
        }
    }

    private var subtitle: String {
        let count = currentState.captures.count
        let roomText = "\(count) room\(count == 1 ? "" : "s")"
        let verb = count == 1 ? "is" : "are"
        return "\(roomText) \(verb) saved on this device and ready to upload. Retry, or start fresh."
    }

    private var retryConfirmationMessage: String {
        let count = currentState.captures.count
        if count >= Self.largeUnitRoomCount {
            return "This will re-upload all \(count) rooms, which may take a while for a unit this size. Make sure you meant to tap this."
        }
        return "This will re-upload \(count) room\(count == 1 ? "" : "s") captured earlier."
    }

    @MainActor
    private func retry() async {
        guard !isRetrying else { return }
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
            if Task.isCancelled { return }
            let floorPlan: FloorPlan
            do {
                floorPlan = try await client.uploadCapture(
                    sessionId: session.id,
                    accessToken: session.accessToken,
                    idempotencyKey: capture.idempotencyKey,
                    bodyJSON: capture.bodyJSON
                )
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
                DiagnosticsLog.shared.record(
                    "Pending upload recovered successfully into session \(session.id)",
                    category: .info
                )
                onFinished(session, floorPlan)
                return
            }
        }
    }
}