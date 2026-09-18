import SwiftUI

struct VuuroMergeStep: Identifiable {
    let id = UUID()
    let label: String
    let isDone: Bool
}

struct MergingView: View {
    let title: String
    let subtitle: String
    let steps: [VuuroMergeStep]
    let onCancel: () -> Void

    @State private var rotation: Double = 0

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(VuuroColor.borderMed, lineWidth: 4)
                    .frame(width: 48, height: 48)
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(VuuroColor.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 48, height: 48)
                    .rotationEffect(.degrees(rotation))
            }
            .onAppear {
                rotation = 0
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }

            Text(title)
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(VuuroColor.textPrimary)
                .padding(.top, 4)

            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(VuuroColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(steps) { step in
                    HStack(spacing: 10) {
                        if step.isDone {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .heavy))
                                .foregroundStyle(Color(red: 24 / 255, green: 24 / 255, blue: 27 / 255))
                                .frame(width: 22, height: 22)
                                .background(VuuroColor.lime, in: Circle())
                        } else {
                            Circle()
                                .stroke(VuuroColor.handle, lineWidth: 2)
                                .frame(width: 22, height: 22)
                        }
                        Text(step.label)
                            .font(.system(size: 14, weight: step.isDone ? .semibold : .regular))
                            .tracking(-0.2)
                            .foregroundStyle(step.isDone ? VuuroColor.textPrimary : VuuroColor.textSecondary)
                    }
                }
            }
            .frame(maxWidth: 280, alignment: .leading)
            .padding(.top, 8)

            Button(action: onCancel) {
                Text("Cancel")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(VuuroColor.danger)
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VuuroColor.bgApp)
    }
}