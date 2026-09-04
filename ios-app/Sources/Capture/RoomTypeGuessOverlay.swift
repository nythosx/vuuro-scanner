//
//  RoomTypeGuessOverlay.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see ../Models/ScanIdentity.swift header.
//

import SwiftUI

struct RoomTypeGuessOverlay: View {
    let guess: RoomTypeClassifier.Guess
    let onConfirm: () -> Void
    let onReject: (String?) -> Void

    @State private var isVisible = true
    @State private var isPickingCorrection = false

    var body: some View {
        if isVisible {
            HStack(spacing: 12) {
                Text("\(RoomTypeClassifier.displayName(for: guess.type))?")
                    .font(.subheadline.weight(.semibold))
                Button {
                    onConfirm()
                    isVisible = false
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Button {
                    isPickingCorrection = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 12)
            .task {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                isVisible = false
            }
            .confirmationDialog("What kind of room is this?", isPresented: $isPickingCorrection, titleVisibility: .visible) {
                ForEach(RoomTypeClassifier.allTypes.filter { $0 != guess.type }, id: \.self) { type in
                    Button(RoomTypeClassifier.displayName(for: type)) {
                        onReject(type)
                        isVisible = false
                    }
                }
                Button("Other") {
                    onReject("other")
                    isVisible = false
                }
                Button("Not sure", role: .cancel) {
                    onReject(nil)
                    isVisible = false
                }
            }
        }
    }
}
