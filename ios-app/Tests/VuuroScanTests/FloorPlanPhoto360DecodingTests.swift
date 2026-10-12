import XCTest
@testable import VuuroScan

final class FloorPlanPhoto360DecodingTests: XCTestCase {

    private func minimalPlanJSON(extraTopLevel: String = "") -> Data {
        let trailing = extraTopLevel.isEmpty ? "" : ",\n  " + extraTopLevel
        let json = """
        {
          "scan_session_id": "s-1",
          "property_id": "p-1",
          "unit_id": "u-1",
          "organisation_id": "o-1",
          "capture_provider": "roomplan",
          "captured_at": "2026-10-12T10:00:00+00:00",
          "measurement_basis": "indicative_nen2580_inspired",
          "purpose": "listing",
          "rooms": [
            {
              "room_id": "r-1",
              "label": "Living room",
              "floor_area_m2": 20.0,
              "perimeter_m": 18.0,
              "bounding_dimensions_m": {"width_m": 5.0, "length_m": 4.0},
              "confidence": "high",
              "outline_m": [[0,0],[5,0],[5,4],[0,4]],
              "coverage": {"score": 90, "confidence_counts": {"high": 1, "medium": 0, "low": 0}, "usable": true, "message": null},
              "openings": [],
              "objects": [],
              "structure_origin_m": null,
              "room_type": null,
              "floor": "Ground",
              "open_edges": []
            }
          ],
          "photos": [],
          "notes": [],
          "capture_location": null\(trailing)
        }
        """
        return Data(json.utf8)
    }

    func testFloorPlanDecodesWithoutPhotos360() throws {
        let plan = try JSONDecoder().decode(FloorPlan.self, from: minimalPlanJSON())
        XCTAssertNil(plan.photos360)
        XCTAssertNil(plan.tour)
    }

    func testFloorPlanDecodesWithPhotos360() throws {
        let extra = """
        "photos_360": [
          {
            "photo_id": "ph-1",
            "room_id": "r-1",
            "url": "/scan-sessions/s-1/photo-uploads/a.jpg",
            "position_m": [1.25, 3.5],
            "heading_deg": 90.0,
            "captured_at": "2026-10-12T10:05:00+00:00"
          },
          {
            "photo_id": "ph-2",
            "room_id": "r-1",
            "url": "/scan-sessions/s-1/photo-uploads/b.jpg",
            "position_m": [4.0, 0.25],
            "heading_deg": 270.0,
            "captured_at": "2026-10-12T10:06:00+00:00"
          }
        ]
        """
        let plan = try JSONDecoder().decode(FloorPlan.self, from: minimalPlanJSON(extraTopLevel: extra))
        let photos = try XCTUnwrap(plan.photos360)
        XCTAssertEqual(photos.count, 2)
        XCTAssertEqual(photos[0].photoId, "ph-1")
        XCTAssertEqual(photos[0].roomId, "r-1")
        XCTAssertEqual(photos[0].positionM, [1.25, 3.5])
        XCTAssertEqual(photos[0].headingDeg, 90.0)
        XCTAssertEqual(photos[0].capturedAt, "2026-10-12T10:05:00+00:00")
        XCTAssertEqual(photos[1].headingDeg, 270.0)
    }

    func testFloorPlanDecodesTourMetadata() throws {
        let extra = """
        "tour": {
          "viewer_url": "https://scan.vuuro.nl/tour/s-1",
          "plan_image_url": "https://scan.vuuro.nl/scan-sessions/s-1/export/floorplan.png",
          "dollhouse_glb_url": null
        }
        """
        let plan = try JSONDecoder().decode(FloorPlan.self, from: minimalPlanJSON(extraTopLevel: extra))
        let tour = try XCTUnwrap(plan.tour)
        XCTAssertEqual(tour.viewerUrl, "https://scan.vuuro.nl/tour/s-1")
        XCTAssertNil(tour.dollhouseGlbUrl)
    }

    func testPhoto360RoundTrips() throws {
        let photo = FloorPlan.Photo360(
            photoId: "ph-1",
            roomId: "r-1",
            url: "/x.jpg",
            positionM: [1.0, 2.0],
            headingDeg: 180.0,
            capturedAt: "2026-10-12T10:00:00+00:00"
        )
        let data = try JSONEncoder().encode(photo)
        let decoded = try JSONDecoder().decode(FloorPlan.Photo360.self, from: data)
        XCTAssertEqual(decoded, photo)
    }

    func testTourMetadataRoundTrips() throws {
        let tour = TourMetadata(
            viewerUrl: "https://scan.vuuro.nl/tour/s-1",
            planImageUrl: "https://scan.vuuro.nl/plan.png",
            dollhouseGlbUrl: "https://scan.vuuro.nl/model.glb"
        )
        let data = try JSONEncoder().encode(tour)
        let decoded = try JSONDecoder().decode(TourMetadata.self, from: data)
        XCTAssertEqual(decoded, tour)
    }

    func testScanSessionResponseDecodesWithoutTour() throws {
        let json = """
        {
          "id": "s-1",
          "property_id": "p-1",
          "unit_id": "u-1",
          "organisation_id": "o-1",
          "purpose": "listing",
          "created_at": "2026-10-12T10:00:00+00:00",
          "status": "created",
          "occupied": false,
          "consent_obtained": false,
          "access_token": "t-1",
          "expires_at": "2027-01-10T10:00:00+00:00",
          "default_floor": "Ground"
        }
        """
        let session = try JSONDecoder().decode(ScanSessionResponse.self, from: Data(json.utf8))
        XCTAssertNil(session.tour)
        XCTAssertEqual(session.defaultFloor, "Ground")
    }

    func testScanSessionResponseDecodesTour() throws {
        let json = """
        {
          "id": "s-1",
          "property_id": "p-1",
          "unit_id": "u-1",
          "organisation_id": "o-1",
          "purpose": "listing",
          "created_at": "2026-10-12T10:00:00+00:00",
          "status": "captured",
          "occupied": false,
          "consent_obtained": false,
          "access_token": "t-1",
          "expires_at": "2027-01-10T10:00:00+00:00",
          "default_floor": "",
          "tour": {
            "viewer_url": "https://scan.vuuro.nl/tour/s-1?token=t-1",
            "plan_image_url": "https://scan.vuuro.nl/scan-sessions/s-1/export/floorplan.png",
            "dollhouse_glb_url": null
          }
        }
        """
        let session = try JSONDecoder().decode(ScanSessionResponse.self, from: Data(json.utf8))
        let tour = try XCTUnwrap(session.tour)
        XCTAssertEqual(tour.viewerUrl, "https://scan.vuuro.nl/tour/s-1?token=t-1")
        XCTAssertNil(tour.dollhouseGlbUrl)
    }
}
