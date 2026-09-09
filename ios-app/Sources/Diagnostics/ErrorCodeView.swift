

import SwiftUI
import UIKit

struct ErrorCodeView: View {
    let error: AppError

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(error.code)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.bold)
            Text(error.userMessage)
                .font(.caption)
            Button {
                UIPasteboard.general.string = error.copyableDetails
            } label: {
                Label("Copy error details", systemImage: "doc.on.doc")
                    .font(.caption)
            }
        }
        .foregroundStyle(.red)
    }
}
