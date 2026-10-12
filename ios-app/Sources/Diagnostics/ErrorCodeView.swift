import SwiftUI
import UIKit

struct ErrorCodeView: View {
    let error: AppError

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(error.userMessage)
                        .font(.callout)
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                Text(error.code)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button {
                    UIPasteboard.general.string = error.copyableDetails
                } label: {
                    Label("Copy details", systemImage: "doc.on.doc")
                        .font(.caption2)
                }
            }
        }
    }

    private var hint: String {
        if error.underlying is CancellationError {
            return "Cancelled."
        }
        if error.isLikelyRetryable {
            return "Try again — this can happen on a spotty connection."
        }
        return "Please try again in a moment."
    }
}