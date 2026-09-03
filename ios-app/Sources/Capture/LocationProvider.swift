//
//  LocationProvider.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see ../Models/ScanIdentity.swift header.
//

import CoreLocation

struct CaptureLocation: Codable {
    let lat: Double
    let lon: Double
    let accuracyM: Double
    let capturedAt: String

    enum CodingKeys: String, CodingKey {
        case lat, lon
        case accuracyM = "accuracy_m"
        case capturedAt = "captured_at"
    }
}

@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CaptureLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
    }

    func currentLocation() async -> CaptureLocation? {
        finish(nil)

        let status = manager.authorizationStatus
        if status == .denied || status == .restricted {
            return nil
        }
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
            Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                self.finish(nil)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let result = CaptureLocation(
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude,
            accuracyM: location.horizontalAccuracy,
            capturedAt: ISO8601DateFormatter().string(from: location.timestamp)
        )
        Task { @MainActor in
            self.finish(result)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.finish(nil)
        }
    }

    private func finish(_ result: CaptureLocation?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: result)
    }
}
