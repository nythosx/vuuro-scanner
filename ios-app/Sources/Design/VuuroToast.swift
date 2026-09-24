import SwiftUI

@MainActor
final class VuuroToast: ObservableObject {
    static let shared = VuuroToast()

    struct Content: Equatable {
        let message: String
        let undoLabel: String?
        let duration: TimeInterval
    }

    @Published fileprivate var content: Content?
    private var undoAction: (() -> Void)?
    private var dismissTask: Task<Void, Never>?
    private var toastToken = 0
    private var visibleSince: Date?
    private var pendingPresentTask: Task<Void, Never>?
    private static let minimumDisplayDuration: TimeInterval = 0.3

    private init() {}

    func show(_ text: String) {
        present(Content(message: text, undoLabel: nil, duration: 2.2), undo: nil)
    }

    func show(_ text: String, undoLabel: String, duration: TimeInterval = 5, undo: @escaping () -> Void) {
        present(Content(message: text, undoLabel: undoLabel, duration: duration), undo: undo)
    }

    fileprivate func triggerUndo() {
        let action = undoAction
        undoAction = nil
        dismissNow()
        action?()
    }

    private func present(_ content: Content, undo: (() -> Void)?) {
        pendingPresentTask?.cancel()
        pendingPresentTask = nil

        if let visibleSince, self.content != nil {
            let elapsed = Date().timeIntervalSince(visibleSince)
            if elapsed < Self.minimumDisplayDuration {
                let remaining = Self.minimumDisplayDuration - elapsed
                pendingPresentTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    guard let self, !Task.isCancelled else { return }
                    self.presentNow(content, undo: undo)
                }
                return
            }
        }
        presentNow(content, undo: undo)
    }

    private func presentNow(_ content: Content, undo: (() -> Void)?) {
        toastToken += 1
        let token = toastToken
        dismissTask?.cancel()
        undoAction = undo
        visibleSince = Date()
        withAnimation(.easeOut(duration: 0.2)) {
            self.content = content
        }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(content.duration * 1_000_000_000))
            guard let self, !Task.isCancelled, token == self.toastToken else { return }
            self.dismissNow()
        }
    }

    private func dismissNow() {
        withAnimation(.easeIn(duration: 0.2)) {
            self.content = nil
        }
        self.undoAction = nil
        self.visibleSince = nil
    }
}

private struct VuuroToastOverlay: View {
    @ObservedObject private var toast = VuuroToast.shared

    var body: some View {
        if let content = toast.content {
            HStack(spacing: 12) {
                Text(content.message)
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(.white)
                if let undoLabel = content.undoLabel {
                    Button(undoLabel) {
                        toast.triggerUndo()
                    }
                    .accessibilityIdentifier("toast.undo")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(VuuroColor.lime)
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, content.undoLabel != nil ? 16 : 20)
            .padding(.vertical, 12)
            .background(VuuroColor.overlayInk, in: Capsule())
            .shadow(color: .black.opacity(0.35), radius: 32, x: 0, y: 8)
            .padding(.bottom, 100)
            .allowsHitTesting(content.undoLabel != nil)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

extension View {
    func vuuroToastHost() -> some View {
        overlay(alignment: .bottom) {
            VuuroToastOverlay()
        }
    }
}