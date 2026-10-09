import ARKit
import QuickLook
import SwiftUI

struct ARQuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: context.coordinator,
            action: #selector(Coordinator.dismiss)
        )
        let navigation = UINavigationController(rootViewController: controller)
        context.coordinator.navigationController = navigation
        return navigation
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        context.coordinator.url = url
        context.coordinator.onDismiss = onDismiss
        (uiViewController.viewControllers.first as? QLPreviewController)?.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        var onDismiss: () -> Void
        weak var navigationController: UINavigationController?

        init(url: URL, onDismiss: @escaping () -> Void) {
            self.url = url
            self.onDismiss = onDismiss
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            let item = ARQuickLookPreviewItem(fileAt: url)
            item.allowsContentScaling = false
            return item
        }

        @objc func dismiss() {
            onDismiss()
        }
    }
}
