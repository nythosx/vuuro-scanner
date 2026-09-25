
import SwiftUI

struct UploadProgressView: View {
    let message: String
    var onCancel: (() -> Void)? = nil
    let stillWorkingAfterSeconds: Int = 5

    @State private var elapsedSeconds = 0

    var body: some View {
        VStack(spacing: 6) {
            ProgressView(elapsedSeconds >= stillWorkingAfterSeconds ? "\(message) still trying… (\(elapsedSeconds)s)" : message)
            if let onCancel {
                Button("Cancel", role: .cancel, action: onCancel)
                    .accessibilityIdentifier("uploadProgress.cancel")
                    .font(.caption)
                    .padding(.top, 2)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                elapsedSeconds += 1
            }
        }
    }
}
