import XCTest
@testable import VuuroScan

final class ScanHistoryViewTests: XCTestCase {

    func testEmptyEntriesFallBackToLegacyMessage() {
        let message = ScanHistoryView.bulkDownloadSummaryMessage(
            isPDF: false, downloaded: 0, skippedNetwork: 0, skippedMissingToken: 0
        )
        XCTAssertEqual(message, "No floor plan images were available to download.")
    }

    func testEmptyEntriesPdfFallBackToLegacyMessage() {
        let message = ScanHistoryView.bulkDownloadSummaryMessage(
            isPDF: true, downloaded: 0, skippedNetwork: 0, skippedMissingToken: 0
        )
        XCTAssertEqual(message, "No floor plan PDFs were available to download.")
    }

    func testAllDownloadedMeansNoMessage() {
        let message = ScanHistoryView.bulkDownloadSummaryMessage(
            isPDF: false, downloaded: 5, skippedNetwork: 0, skippedMissingToken: 0
        )
        XCTAssertNil(message)
    }

    func testNetworkOnlySkipsMatchLegacyWording() {
        let message = ScanHistoryView.bulkDownloadSummaryMessage(
            isPDF: false, downloaded: 3, skippedNetwork: 2, skippedMissingToken: 0
        )
        XCTAssertEqual(message, "Downloaded 3 image(s); skipped 2 sessions.")
    }

    func testPdfNetworkOnlySkipsUsePdfNoun() {
        let message = ScanHistoryView.bulkDownloadSummaryMessage(
            isPDF: true, downloaded: 3, skippedNetwork: 2, skippedMissingToken: 0
        )
        XCTAssertEqual(message, "Downloaded 3 PDF(s); skipped 2 sessions.")
    }

    func testSingleNetworkSkipUsesSingularSession() {
        let message = ScanHistoryView.bulkDownloadSummaryMessage(
            isPDF: false, downloaded: 1, skippedNetwork: 1, skippedMissingToken: 0
        )
        XCTAssertEqual(message, "Downloaded 1 image(s); skipped 1 session.")
    }

    func testMissingTokenOnlyIsDistinguishedFromNetwork() {
        let message = ScanHistoryView.bulkDownloadSummaryMessage(
            isPDF: false, downloaded: 3, skippedNetwork: 0, skippedMissingToken: 2
        )
        XCTAssertEqual(message, "Downloaded 3 image(s); skipped 2 sessions that are missing their access token.")
    }

    func testSingleMissingTokenUsesSingularSession() {
        let message = ScanHistoryView.bulkDownloadSummaryMessage(
            isPDF: true, downloaded: 2, skippedNetwork: 0, skippedMissingToken: 1
        )
        XCTAssertEqual(message, "Downloaded 2 PDF(s); skipped 1 session that are missing their access token.")
    }

    func testBothSkipsAreReportedSeparately() {
        let message = ScanHistoryView.bulkDownloadSummaryMessage(
            isPDF: true, downloaded: 1, skippedNetwork: 3, skippedMissingToken: 2
        )
        XCTAssertEqual(message, "Downloaded 1 PDF(s); skipped 3 sessions that failed and 2 that are missing their access token.")
    }

    func testAllMissingTokenMeansNothingDownloaded() {
        let message = ScanHistoryView.bulkDownloadSummaryMessage(
            isPDF: false, downloaded: 0, skippedNetwork: 0, skippedMissingToken: 4
        )
        XCTAssertEqual(message, "No floor plan images were downloaded — 4 sessions are missing their access token on this device.")
    }

    func testSingleMissingTokenWithNoDownloads() {
        let message = ScanHistoryView.bulkDownloadSummaryMessage(
            isPDF: true, downloaded: 0, skippedNetwork: 0, skippedMissingToken: 1
        )
        XCTAssertEqual(message, "No floor plan PDFs were downloaded — 1 session are missing their access token on this device.")
    }

    func testAllNetworkSkipsMeansNothingDownloaded() {
        let message = ScanHistoryView.bulkDownloadSummaryMessage(
            isPDF: false, downloaded: 0, skippedNetwork: 3, skippedMissingToken: 0
        )
        XCTAssertEqual(message, "No floor plan images were available to download.")
    }
}
