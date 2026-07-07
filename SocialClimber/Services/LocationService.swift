import Foundation
import CoreLocation

/// Optional, on-demand location lookup: resolves the current city once per
/// request so the dashboard can show which known people live nearby.
/// Never tracks in the background, never stores a location, never leaves
/// the device — only the resolved city name is kept, in memory, for the
/// current session.
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    var authorized = false

    override init() {
        super.init()
        manager.delegate = self
        authorized = Self.isAuthorized(manager.authorizationStatus)
    }

    private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }

    func requestAccess() async -> Bool {
        if authorized { return true }
        let status = manager.authorizationStatus
        guard status == .notDetermined else { return false }

        return await withCheckedContinuation { continuation in
            self.authRequestContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    private var authRequestContinuation: CheckedContinuation<Bool, Never>?

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let granted = Self.isAuthorized(manager.authorizationStatus)
        authorized = granted
        authRequestContinuation?.resume(returning: granted)
        authRequestContinuation = nil
    }

    /// Resolves the current city (and optionally state/country) on-device,
    /// or `nil` if location isn't authorized, unavailable, or unresolvable.
    func currentCity() async -> String? {
        guard authorized else { return nil }
        guard let location = await requestOneShotLocation() else { return nil }

        let geocoder = CLGeocoder()
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else { return nil }
        return placemark.locality ?? placemark.subAdministrativeArea ?? placemark.administrativeArea
    }

    private func requestOneShotLocation() async -> CLLocation? {
        if let cached = manager.location { return cached }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        continuation?.resume(returning: locations.last)
        continuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        continuation?.resume(returning: nil)
        continuation = nil
    }
}
