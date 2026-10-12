import UIKit

enum ShareSheetPresenter {
    @MainActor
    @discardableResult
    static func present(items: [Any]) -> Bool {
        guard let presenter = TopViewController.find() else { return false }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(controller, animated: true)
        return true
    }
}
