import QuickLook
import SwiftUI

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    var onDismiss: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator

        let navController = UINavigationController(rootViewController: controller)
        context.coordinator.navigationController = navController

        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: context.coordinator,
            action: #selector(Coordinator.dismiss)
        )

        return navController
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

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as QLPreviewItem
        }

        @objc func dismiss() {
            onDismiss()
        }
    }
}