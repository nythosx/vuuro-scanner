
import CoreLocation

@MainActor
final class HeadingProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Double?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var callToken = 0

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

        callToken += 1
        let token = callToken
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.startUpdatingHeading()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, token == self.callToken else { return }
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
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let continuation else { return }
        self.continuation = nil
        manager.stopUpdatingHeading()
        continuation.resume(returning: result)
    }
}
