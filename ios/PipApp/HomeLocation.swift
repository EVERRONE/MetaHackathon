import CoreLocation
import PipCore

/// Roughly where the phone is (Wi-Fi and GPS, tens of metres), only to tell whether a saved room
/// can be here: maps made in another home or building are not tried, so ARKit is not kept waiting
/// for a room that is far away. Asked for once the user lets Pip remember (the memory consent);
/// kept only with the map pieces on this iPhone.
final class HomeLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var current: CLLocation?
    /// Asked for only once the user agreed to be remembered (`start`), also when location access
    /// was granted before.
    private var started = false
    /// A new fix came in.
    var onUpdate: ((GeoPoint) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func start() {
        started = true
        // A fix the system already has, if it is recent: available at once.
        if let l = manager.location, -l.timestamp.timeIntervalSinceNow < 600 { current = l }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        default: break
        }
    }

    /// The current fix, when it is good enough to tell buildings apart.
    var point: GeoPoint? {
        guard let l = current, l.horizontalAccuracy > 0, l.horizontalAccuracy <= 300, -l.timestamp.timeIntervalSinceNow < 1800 else { return nil }
        return GeoPoint(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude, accuracy: l.horizontalAccuracy)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Also called when the manager is made, at launch.
        guard started else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        current = l
        if let p = point { onUpdate?(p) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
