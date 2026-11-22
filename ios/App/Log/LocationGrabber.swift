import Foundation
import CoreLocation

/// One location fix for a new refuel (the pump's coordinates). Asks for when-in-use permission the first
/// time; gives nil if it's denied, restricted, fails or takes longer than `timeout`. No network call of
/// the app's own; works offline (GPS).
@MainActor
final class LocationGrabber: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let timeout: Duration = .seconds(20)

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    func grabOnce() async -> (lat: Double, lon: Double)? {
        guard continuation == nil else { return nil }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        let timer = Task { [weak self] in
            try? await Task.sleep(for: Self.timeout)
            self?.finish(nil)
        }
        defer { timer.cancel() }
        let c = await withCheckedContinuation { (c: CheckedContinuation<CLLocationCoordinate2D?, Never>) in
            continuation = c
            start(manager.authorizationStatus)
        }
        return c.map { ($0.latitude, $0.longitude) }
    }

    private func start(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined: manager.requestWhenInUseAuthorization()  // answer arrives in the delegate
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        default: finish(nil)
        }
    }

    private func finish(_ c: CLLocationCoordinate2D?) {
        continuation?.resume(returning: c)
        continuation = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard self.continuation != nil, status != .notDetermined else { return }
            self.start(status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let c = locations.last?.coordinate
        Task { @MainActor in self.finish(c) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
}
