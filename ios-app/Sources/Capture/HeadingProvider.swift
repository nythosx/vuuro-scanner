
import CoreLocation

@MainActor
final class HeadingProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Double?, Never>?

    override init() {
        super.init()
        manager.delegate = self
    }

    func currentHeadingDeg() async -> Double? {
        finish(nil)

        guard CLLocationManager.headingAvailable() else { return nil }

        let status = manager.authorizationStatus
        if status == .denied || status == .restricted {
            return nil
        }
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.startUpdatingHeading()
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.finish(nil)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        let bearing = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        guard bearing >= 0 else { return }
        Task { @MainActor in
            self.finish(bearing)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.finish(nil)
        }
    }

    private func finish(_ result: Double?) {
        guard let continuation else { return }
        self.continuation = nil
        manager.stopUpdatingHeading()
        continuation.resume(returning: result)
    }
}
