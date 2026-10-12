
import UIKit

final class ShareCodeItemSource: NSObject, UIActivityItemSource {
    private let code: String
    private let subject: String
    private let messageBody: String

    init(code: String, subject: String, messageBody: String) {
        self.code = code
        self.subject = subject
        self.messageBody = messageBody
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        code
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        "\(messageBody)\n\n\(code)"
    }

    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        subject
    }
}
