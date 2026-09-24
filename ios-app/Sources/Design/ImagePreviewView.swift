import SwiftUI

struct ImagePreviewView: View {
    let image: UIImage
    let onClose: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            scale = max(1.0, lastScale * value.magnification)
                        }
                        .onEnded { _ in
                            lastScale = scale
                            if scale <= 1.0 {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    offset = .zero
                                    lastOffset = .zero
                                }
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            guard scale > 1.0 else { return }
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            lastOffset = offset
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if scale > 1.0 {
                            scale = 1.0
                            lastScale = 1.0
                            offset = .zero
                            lastOffset = .zero
                        } else {
                            scale = 2.5
                            lastScale = 2.5
                        }
                    }
                }
                .onTapGesture(count: 1) {
                    onClose()
                }
                .padding(20)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .accessibilityIdentifier("imagePreview.close")
            .padding(.leading, 20)
            .padding(.top, 16)
        }
    }
}