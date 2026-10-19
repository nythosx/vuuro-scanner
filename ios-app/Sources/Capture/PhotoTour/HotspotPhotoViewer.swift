import SwiftUI
import UIKit

struct HotspotPhotoTarget: Identifiable {
    let photo: FloorPlan.Photo360
    var id: String { photo.photoId }
}

struct HotspotPhotoViewer: View {
    let session: ScanSessionResponse
    let photo: FloorPlan.Photo360
    let onClose: () -> Void

    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var loadError: AppError?

    private let client = ScanServiceClient()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await loadImage() }
    }

    private var header: some View {
        HStack {
            Text(vuuroLocalized("Tour photo"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .accessibilityIdentifier("hotspotPhotoViewer.close")
            .accessibilityLabel(vuuroLocalized("Close photo"))
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            ZoomableImage(image: image)
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
                .accessibilityIdentifier("hotspotPhotoViewer.image")
        } else if isLoading {
            ProgressView().tint(.white)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "photo")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.4))
                Text(vuuroLocalized("Couldn't load this photo."))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                if let loadError {
                    ErrorCodeView(error: loadError)
                        .frame(maxWidth: 320)
                }
                Button(vuuroLocalized("Try again")) {
                    Task { await loadImage() }
                }
                .accessibilityIdentifier("hotspotPhotoViewer.retry")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(Color.white.opacity(0.12), in: Capsule())
            }
            .padding(.horizontal, 20)
        }
    }

    @MainActor
    private func loadImage() async {
        if let cached = PhotoImageCache.shared.image(for: photo.url) {
            image = cached
            return
        }
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let data = try await client.fetchPhotoData(url: photo.url, accessToken: session.accessToken)
            guard let decoded = UIImage(data: data) else {
                throw PlainError(message: "The photo came back from the Scan Service but could not be decoded.")
            }
            PhotoImageCache.shared.store(decoded, for: photo.url)
            image = decoded
        } catch is CancellationError {
        } catch {
            loadError = AppError(site: .photoLoad, underlying: error)
        }
    }
}
