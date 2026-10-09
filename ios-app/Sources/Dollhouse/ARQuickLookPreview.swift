import ARKit
import QuickLook
import UIKit

final class ARQuickLookPresenter: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    static let shared = ARQuickLookPresenter()

    private var url: URL?
    private var onDismiss: (() -> Void)?
    private weak var controller: QLPreviewController?

    @MainActor
    @discardableResult
    func present(url: URL, onDismiss: @escaping () -> Void = {}) -> Bool {
        guard controller == nil, let presenter = ARQuickLookPresenter.topViewController() else { return false }
        self.url = url
        self.onDismiss = onDismiss
        let preview = QLPreviewController()
        preview.dataSource = self
        preview.delegate = self
        preview.modalPresentationStyle = .fullScreen
        controller = preview
        presenter.present(preview, animated: true)
        return true
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        url == nil ? 0 : 1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        let item = ARQuickLookPreviewItem(fileAt: url ?? FileManager.default.temporaryDirectory)
        item.allowsContentScaling = false
        return item
    }

    func previewControllerDidDismiss(_ controller: QLPreviewController) {
        let callback = onDismiss
        url = nil
        onDismiss = nil
        self.controller = nil
        callback?()
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
