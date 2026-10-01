import SwiftUI

struct RelocalizeCountdownView: View {
    let status: RelocalizeStepView.Status
    let totalSeconds: Int
    let onSkip: () -> Void
    let onRetry: () -> Void

    @State private var remaining: Int
    @State private var task: Task<Void, Never>?

    init(
        status: RelocalizeStepView.Status,
        totalSeconds: Int = 45,
        onSkip: @escaping () -> Void,
        onRetry: @escaping () -> Void
    ) {
        self.status = status
        self.totalSeconds = totalSeconds
        self.onSkip = onSkip
        self.onRetry = onRetry
        _remaining = State(initialValue: totalSeconds)
    }

    var body: some View {
        RelocalizeStepView(
            status: status,
            secondsRemaining: remaining,
            onSkip: onSkip,
            onRetry: onRetry
        )
        .onAppear { restart() }
        .onDisappear { stop() }
        .onChange(of: status) { _, newValue in
            if newValue == .looking {
                restart()
            } else {
                stop()
            }
        }
    }

    private func restart() {
        stop()
        remaining = totalSeconds
        task = Task { @MainActor in
            while !Task.isCancelled, remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                remaining = max(0, remaining - 1)
            }
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
    }
}
