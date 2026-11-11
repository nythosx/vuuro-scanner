import Foundation

enum PhotoTourSettings {
    static let afterRoomKey = "photoTourAfterRoomEnabled"

    static func showsStep(photosAfterRoom: Bool, walkthrough: Bool) -> Bool {
        photosAfterRoom || walkthrough
    }
}
