import SwiftUI

struct ImagePreviewView: View {
    let image: UIImage
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            ZoomableImage(image: image, onSingleTap: onClose)
                .padding(.horizontal, 20)
                .padding(.vertical, 64)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color(uiColor: .label))
                    .frame(width: 44, height: 44)
                    .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                    .overlay(Circle().stroke(Color(uiColor: .separator), lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 1)
            }
            .accessibilityIdentifier("imagePreview.close")
            .accessibilityLabel("Close image preview")
            .padding(.leading, 20)
            .padding(.top, 16)
        }
    }
}
