import Foundation

struct AppError {
    let site: Site
    let underlying: Error?
    let occurredAt: Date

    @MainActor
    init(site: Site, underlying: Error?) {
        self.site = site
        self.underlying = underlying
        self.occurredAt = Date()
        DiagnosticsLog.shared.record(copyableDetails, category: .error)
    }

    enum Site: String {
        case healthCheck = "HEALTH_CHECK"
        case sessionCreate = "SESSION_CREATE"
        case captureUpload = "CAPTURE_UPLOAD"
        case captureNoRoom = "CAPTURE_NO_ROOM"
        case captureFailed = "CAPTURE_FAILED"
        case photoAdd = "PHOTO_ADD"
        case photoUpload = "PHOTO_UPLOAD"
        case photoTooLarge = "PHOTO_TOO_LARGE"
        case noteAdd = "NOTE_ADD"
        case noteUpdate = "NOTE_UPDATE"
        case noteDelete = "NOTE_DELETE"
        case photoDelete = "PHOTO_DELETE"
        case roomTypeUpdate = "ROOM_TYPE_UPDATE"
        case roomLabelUpdate = "ROOM_LABEL_UPDATE"
        case resultImageLoad = "RESULT_IMAGE_LOAD"
        case resultImageDecode = "RESULT_IMAGE_DECODE"
        case resultPDFLoad = "RESULT_PDF_LOAD"
        case accessLog = "ACCESS_LOG"
        case historyImageDownload = "HISTORY_IMAGE_DOWNLOAD"
        case historyPDFDownload = "HISTORY_PDF_DOWNLOAD"
        case historySessionFetch = "HISTORY_SESSION_FETCH"
        case historyServerDelete = "HISTORY_SERVER_DELETE"
        case uploadCancelled = "UPLOAD_CANCELLED"

        /// Only used when there's no thrown Error to describe the failure
        /// (e.g. capture finished but RoomPlan reported no usable room) —
        /// a real, code-checked state, not a placeholder for "unknown."
        var defaultMessage: String {
            switch self {
            case .captureNoRoom:
                return "Capture finished without a usable room."
            case .resultImageDecode:
                return "The floor plan image couldn't be decoded."
            case .photoUpload:
                return "Couldn't read the selected photo."
            case .photoTooLarge:
                return "Photos are limited to 25MB. Please choose a smaller photo."
            case .uploadCancelled:
                return "Upload cancelled."
            default:
                return "Something went wrong."
            }
        }
    }

    var code: String {
        if let reasonSuffix {
            return "VS-\(site.rawValue)-\(reasonSuffix)"
        }
        return "VS-\(site.rawValue)"
    }

    private var reasonSuffix: String? {
        guard let underlying else { return nil }
        if let scanError = underlying as? ScanServiceError {
            switch scanError {
            case .unexpectedStatus(let status, _):
                return "\(status)"
            case .transport(let transportError):
                let nsError = transportError as NSError
                if nsError.domain == NSURLErrorDomain {
                    return "NETWORK-\(nsError.code)"
                }
                return "NETWORK"
            }
        }
        return "ERR"
    }

    var userMessage: String {
        underlying?.localizedDescription ?? site.defaultMessage
    }

    var isLikelyRetryable: Bool {
        guard let scanError = underlying as? ScanServiceError,
              case .unexpectedStatus(let status, _) = scanError else { return true }
        if status == 429 {
            return true
        }
        return !(400...499).contains(status)
    }


    var copyableDetails: String {
        """
        Vuuro Scan error \(code)
        When: \(occurredAt.formatted(date: .abbreviated, time: .standard))
        What: \(userMessage)
        """
    }
}

struct PlainError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
