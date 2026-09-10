

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
                    Text(error.isLikelyRetryable ? "Try again — this can happen on a spotty connection." : "Please try again in a moment.")
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
}
