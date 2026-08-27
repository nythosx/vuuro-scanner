//
//  AppError.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see ../Models/ScanIdentity.swift header.
//
//  Every error the app shows a user is wrapped here so its support code is
//  DERIVED from the real underlying failure, never guessed or hand-typed at
//  each call site. That's the whole point: a code that claims a cause other
//  than what actually happened is a false result, and this file is the one
//  place that decides the mapping — every screen just displays what comes
//  out of it. `site` says WHERE in the app the failure happened (a real,
//  fixed call site, not inferred); the suffix says WHY, read straight off
//  the real HTTP status or transport error when one exists.
//

import Foundation

struct AppError {
    let site: Site
    let underlying: Error?
    let occurredAt: Date = Date()

    enum Site: String {
        case sessionCreate = "SESSION_CREATE"
        case captureUpload = "CAPTURE_UPLOAD"
        case captureNoRoom = "CAPTURE_NO_ROOM"
        case captureFailed = "CAPTURE_FAILED"
        case photoAdd = "PHOTO_ADD"
        case photoUpload = "PHOTO_UPLOAD"
        case noteAdd = "NOTE_ADD"
        case resultImageLoad = "RESULT_IMAGE_LOAD"
        case resultImageDecode = "RESULT_IMAGE_DECODE"
        case resultPDFLoad = "RESULT_PDF_LOAD"
        case accessLog = "ACCESS_LOG"
        case historyImageDownload = "HISTORY_IMAGE_DOWNLOAD"
        case historyPDFDownload = "HISTORY_PDF_DOWNLOAD"

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
            default:
                return "Something went wrong."
            }
        }
    }

    /// e.g. "VS-CAPTURE_UPLOAD-500", "VS-SESSION_CREATE-NETWORK-1009",
    /// or "VS-CAPTURE_NO_ROOM" when there's no thrown error to read a
    /// reason from — every segment is real, nothing is filled in to make
    /// the code look more specific than what's actually known.
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

    /// Everything needed to diagnose the failure, safe to paste into a
    /// message to Joven — no access token or other session secret in here.
    var copyableDetails: String {
        """
        Vuuro Scan error \(code)
        When: \(occurredAt.formatted(date: .abbreviated, time: .standard))
        What: \(userMessage)
        """
    }
}

/// Wraps a plain string failure reason (e.g. CaptureCoordinator's own
/// capture-failure messages, which are already strings by the time they
/// reach here, not typed Errors) so it can still flow through AppError's
/// normal underlying-error path instead of a separate code path.
struct PlainError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
