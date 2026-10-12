import CoreLocation
import Foundation

/// The `CLLocationManager` objects the recorder needs beside the live updates, on the
/// main actor, where their delegate callbacks arrive: one for the low-accuracy warm phase
/// after a stop, one for significant-change and visit monitoring, which survive
/// termination and relaunch the app. The recorder actor holds no manager itself; it
/// drives these through `MainActor.run` and they hand every delivery back to it.
@MainActor
final class LocationBridges {
    static let shared = LocationBridges()

    let warm = WarmBridge()
    let background = BackgroundBridge()

    var recorder: LocationRecorder? {
        didSet {
            warm.recorder = recorder
            background.recorder = recorder
        }
    }

    var authorizationStatus: CLAuthorizationStatus {
        background.manager.authorizationStatus
    }
}

/// Hundred-metre updates for the minutes after a stop, cheaper than the live sequence.
@MainActor
final class WarmBridge: NSObject, CLLocationManagerDelegate {
    let manager = CLLocationManager()
    var recorder: LocationRecorder?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = false
    }

    func start() {
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map(Fix.init)
        MainActor.assumeIsolated {
            guard let recorder else { return }
            Task { await recorder.warmFixes(fixes) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            guard let recorder else { return }
            Task { await recorder.note(.error("warm: \(message)")) }
        }
    }
}

/// What iOS keeps running for the app while it sleeps or is gone: significant changes and
/// visits. Both relaunch a terminated app; the delegate then delivers into the fresh process.
@MainActor
final class BackgroundBridge: NSObject, CLLocationManagerDelegate {
    let manager = CLLocationManager()
    var recorder: LocationRecorder?

    override init() {
        super.init()
        manager.delegate = self
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = false
    }

    func startSignificantChanges() {
        manager.startMonitoringSignificantLocationChanges()
    }

    func stopSignificantChanges() {
        manager.stopMonitoringSignificantLocationChanges()
    }

    func startVisits() {
        manager.startMonitoringVisits()
    }

    func stopVisits() {
        manager.stopMonitoringVisits()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map(Fix.init)
        MainActor.assumeIsolated {
            guard let recorder else { return }
            Task { await recorder.significantChangeFixes(fixes) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let sample = VisitSample(visit)
        MainActor.assumeIsolated {
            guard let recorder else { return }
            Task { await recorder.visit(sample) }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard let recorder else { return }
            Task { await recorder.authorizationChanged(status) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            guard let recorder else { return }
            Task { await recorder.note(.error("background: \(message)")) }
        }
    }
}

/// A visit as a value.
struct VisitSample: Sendable, Equatable {
    var coordinate: Coordinate
    var horizontalAccuracy: Double
    var arrival: Date?
    var departure: Date?

    init(_ visit: CLVisit) {
        coordinate = Coordinate(latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude)
        horizontalAccuracy = visit.horizontalAccuracy
        arrival = visit.arrivalDate == .distantPast ? nil : visit.arrivalDate
        departure = visit.departureDate == .distantFuture ? nil : visit.departureDate
    }
}

extension CLAuthorizationStatus {
    var text: String {
        switch self {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorizedAlways: "always"
        case .authorizedWhenInUse: "whenInUse"
        @unknown default: "unknown"
        }
    }
}
