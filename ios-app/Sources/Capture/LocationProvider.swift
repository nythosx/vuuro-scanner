
import CoreLocation

struct CaptureLocation: Codable {
    let lat: Double
    let lon: Double
    let accuracyM: Double
    let capturedAt: String?

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
    private var timeoutTask: Task<Void, Never>?
    private var callToken = 0
    private var pendingLocationRequest = false

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

        callToken += 1
        let token = callToken
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            if status == .notDetermined {
                pendingLocationRequest = true
                manager.requestWhenInUseAuthorization()
            } else {
                manager.requestLocation()
            }
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, token == self.callToken else { return }
                self.finish(nil)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.pendingLocationRequest else { return }
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                self.pendingLocationRequest = false
                manager.requestLocation()
            case .denied, .restricted:
                self.pendingLocationRequest = false
                self.finish(nil)
            default:
                break
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
        timeoutTask?.cancel()
        timeoutTask = nil
        pendingLocationRequest = false
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: result)
    }
}
