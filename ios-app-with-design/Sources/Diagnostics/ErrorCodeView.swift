//
//  ErrorCodeView.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see ../Models/ScanIdentity.swift header.
//
//  Renders an AppError consistently everywhere it can appear: the code (for
//  Mark to read out or screenshot), the human message, and a one-tap copy
//  action so the whole diagnostic block reaches Joven exactly as generated —
//  no retyping it by hand, which would be its own source of a wrong report.
//

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
                .font(VuuroFont.body(13))
            Button {
                UIPasteboard.general.string = error.copyableDetails
            } label: {
                Label("Copy error details", systemImage: "doc.on.doc")
                    .font(VuuroFont.body(12))
            }
        }
        .foregroundStyle(VuuroColor.danger)
    }
}
