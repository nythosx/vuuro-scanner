import XCTest
@testable import VuuroScan

final class ScanServiceClientTourTests: XCTestCase {

    private let token = "3f2b8c1e-9a4d-4e6b-8c2f-1d5e7a9b0c3d"

    private func session(tour: TourMetadata? = nil, accessToken: String? = nil) -> ScanSessionResponse {
        ScanSessionResponse(
            id: "s-1",
            propertyId: "prop-1",
            unitId: "unit-1",
            organisationId: "org-1",
            purpose: "listing",
            createdAt: "2026-10-12T10:00:00+00:00",
            status: "captured",
            occupied: false,
            consentObtained: false,
            accessToken: accessToken ?? token,
            expiresAt: "2027-01-10T10:00:00+00:00",
            defaultFloor: "Ground",
            tour: tour
        )
    }

    private func client(configured: Bool = true) -> ScanServiceClient {
        var client = ScanServiceClient()
        client.baseURL = URL(string: "https://scan.example.test")!
        client.isConfigured = configured
        return client
    }

    private func floorPlan(tour: TourMetadata?) throws -> FloorPlan {
        let tourJSON: String
        if let tour {
            tourJSON = "{\"viewer_url\":\"\(tour.viewerUrl)\",\"plan_image_url\":\"\(tour.planImageUrl)\",\"dollhouse_glb_url\":null}"
        } else {
            tourJSON = "null"
        }
        let json = """
        {
          "scan_session_id":"s-1","property_id":"p","unit_id":"u","organisation_id":"o",
          "capture_provider":"roomplan","captured_at":"2026-10-12T10:00:00+00:00",
          "measurement_basis":"indicative_nen2580_inspired","purpose":"listing",
          "rooms":[{"room_id":"r-1","label":"Room 1","floor_area_m2":12.0,"perimeter_m":14.0,
            "bounding_dimensions_m":{"width_m":4.0,"length_m":3.0},"confidence":"high",
            "outline_m":[[0,0],[4,0],[4,3],[0,3]],
            "coverage":{"score":90,"confidence_counts":{"high":1,"medium":0,"low":0},"usable":true,"message":null},
            "openings":[],"objects":[],"structure_origin_m":null,"room_type":null,"floor":"Ground","open_edges":[]}],
          "photos":[],"notes":[],"capture_location":null,"tour":\(tourJSON)
        }
        """
        return try JSONDecoder().decode(FloorPlan.self, from: Data(json.utf8))
    }

    func testPrefersServerProvidedTourURL() throws {
        let tour = TourMetadata(
            viewerUrl: "https://scan.example.test/tour/s-1?token=server&lang=en",
            planImageUrl: "https://scan.example.test/plan.png",
            dollhouseGlbUrl: nil
        )
        let url = client().webTourURL(session: session(tour: tour), floorPlan: nil)
        XCTAssertEqual(url?.absoluteString, tour.viewerUrl)
    }

    func testFloorPlanTourWinsOverSessionTour() throws {
        let sessionTour = TourMetadata(
            viewerUrl: "https://old.example/tour/s-1",
            planImageUrl: "https://old.example/plan.png",
            dollhouseGlbUrl: nil
        )
        let planTour = TourMetadata(
            viewerUrl: "https://new.example/tour/s-1",
            planImageUrl: "https://new.example/plan.png",
            dollhouseGlbUrl: nil
        )
        let plan = try floorPlan(tour: planTour)
        let url = client().webTourURL(session: session(tour: sessionTour), floorPlan: plan)
        XCTAssertEqual(url?.absoluteString, planTour.viewerUrl)
    }

    func testConstructsFallbackWhenNoTourMetadataExists() throws {
        let url = client().webTourURL(session: session(), floorPlan: nil)
        let string = url?.absoluteString ?? ""
        XCTAssertTrue(string.hasPrefix("https://scan.example.test/tour/s-1?"), string)
        XCTAssertTrue(string.contains("token=\(token)"), string)
        XCTAssertTrue(string.contains("lang="), string)
    }

    func testFallbackUsesTheSessionTokenVerbatim() throws {
        let url = client().webTourURL(session: session(accessToken: token), floorPlan: nil)
        XCTAssertTrue(url?.absoluteString.contains("token=\(token)") == true)
    }

    func testReturnsNilWhenNotConfiguredAndNoServerURL() throws {
        let url = client(configured: false).webTourURL(session: session(), floorPlan: nil)
        XCTAssertNil(url)
    }

    func testServerURLStillWorksWhenClientIsNotConfigured() throws {
        let tour = TourMetadata(
            viewerUrl: "https://scan.example.test/tour/s-1?token=server",
            planImageUrl: "https://scan.example.test/plan.png",
            dollhouseGlbUrl: nil
        )
        let url = client(configured: false).webTourURL(session: session(tour: tour), floorPlan: nil)
        XCTAssertEqual(url?.absoluteString, tour.viewerUrl)
    }

    func testFallbackIgnoresFloorPlanWithoutTour() throws {
        let plan = try floorPlan(tour: nil)
        let url = client().webTourURL(session: session(), floorPlan: plan)
        XCTAssertTrue(url?.absoluteString.hasPrefix("https://scan.example.test/tour/s-1?") == true)
    }
}
