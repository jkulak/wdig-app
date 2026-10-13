import CoreLocation
import Foundation

/// What the recorder asks of Core Location, so a test can stand in for all of it: the session
/// that holds the authorization, the live sequence, the hundred-metre warm updates after a
/// stop, the significant changes and visits that outlive the process, and the fence around a
/// stop. Deliveries go the other way, into the recorder it was started for.
protocol LocationProviding: Sendable {
    /// Opens what a whole recording needs and points every delivery at the recorder.
    func start(for recorder: LocationRecorder) async
    func stop() async
    /// The live sequence for a way of moving; it ends when the recorder stops reading it.
    func liveUpdates(_ kind: MovementKind) async -> AsyncThrowingStream<LiveUpdate, any Error>
    func startWarm() async
    func stopWarm() async
    func startVisits() async
    func stopVisits() async
    func setFence(around center: Coordinate, radius: Double) async
    func removeFence() async
}

/// A live update as a value, so the recorder can be handed one without Core Location.
struct LiveUpdate: Sendable, Equatable {
    var authorizationDenied: Bool
    var stationary: Bool
    var fix: Fix?

    init(_ update: CLLocationUpdate) {
        authorizationDenied = update.authorizationDenied || update.authorizationDeniedGlobally
        stationary = update.stationary
        fix = update.location.map(Fix.init)
    }

    init(authorizationDenied: Bool = false, stationary: Bool = false, fix: Fix? = nil) {
        self.authorizationDenied = authorizationDenied
        self.stationary = stationary
        self.fix = fix
    }
}

/// Core Location itself, on the main actor, where the managers' delegate callbacks arrive: a
/// service session for the authorization, a monitor for the fence, the live sequence, and one
/// `CLLocationManager` each for the low-accuracy warm phase and for significant-change and
/// visit monitoring, which survive termination and relaunch the app. The recorder actor holds
/// none of this itself; it drives it through `LocationProviding` and every delivery goes back
/// to it.
@MainActor
final class LocationBridges: LocationProviding {
    static let shared = LocationBridges()
    static let fenceIdentifier = "stop"

    let warm = WarmBridge()
    let background = BackgroundBridge()
    private var session: CLServiceSession?
    private var diagnosticsTask: Task<Void, Never>?
    private var monitor: CLMonitor?
    private var monitorTask: Task<Void, Never>?

    var recorder: LocationRecorder? {
        didSet {
            warm.recorder = recorder
            background.recorder = recorder
        }
    }

    var authorizationStatus: CLAuthorizationStatus {
        background.manager.authorizationStatus
    }

    func start(for recorder: LocationRecorder) async {
        self.recorder = recorder
        background.startSignificantChanges()
        let session = CLServiceSession(authorization: .always)
        self.session = session
        diagnosticsTask = Task { [weak self] in
            do {
                for try await diagnostic in session.diagnostics {
                    guard let recorder = self?.recorder else { return }
                    if diagnostic.authorizationDenied || diagnostic.authorizationDeniedGlobally {
                        await recorder.note(.error("location authorization denied"))
                    } else if diagnostic.alwaysAuthorizationDenied {
                        await recorder.note(.error("always authorization denied, while-using only"))
                    } else if diagnostic.authorizationRestricted {
                        await recorder.note(.error("location restricted"))
                    }
                }
            } catch {
                await self?.recorder?.note(.error("session diagnostics: \(error.localizedDescription)"))
            }
        }
        let monitor = await CLMonitor("WDIGRecorder")
        self.monitor = monitor
        if await monitor.identifiers.contains(Self.fenceIdentifier) {
            await monitor.remove(Self.fenceIdentifier)
        }
        monitorTask = Task { [weak self] in
            do {
                for try await event in await monitor.events {
                    guard event.identifier == Self.fenceIdentifier, event.state == .unsatisfied else { continue }
                    guard let recorder = self?.recorder else { return }
                    await recorder.fenceExited()
                }
            } catch {
                await self?.recorder?.note(.error("monitor: \(error.localizedDescription)"))
            }
        }
    }

    func stop() {
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        warm.stop()
        background.stopVisits()
        background.stopSignificantChanges()
        session?.invalidate()
        session = nil
        monitor = nil
    }

    /// The sequence runs off the main actor: a fix needs nothing from it on its way to the recorder.
    nonisolated func liveUpdates(_ kind: MovementKind) -> AsyncThrowingStream<LiveUpdate, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // The configuration is chosen in the task: Core Location does not mark it Sendable.
                let configuration: CLLocationUpdate.LiveConfiguration = kind == .vehicle ? .otherNavigation : .fitness
                do {
                    for try await update in CLLocationUpdate.liveUpdates(configuration) {
                        continuation.yield(LiveUpdate(update))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func startWarm() {
        warm.start()
    }

    func stopWarm() {
        warm.stop()
    }

    func startVisits() {
        background.startVisits()
    }

    func stopVisits() {
        background.stopVisits()
    }

    func setFence(around center: Coordinate, radius: Double) async {
        guard let monitor else { return }
        let condition = CLMonitor.CircularGeographicCondition(
            center: CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude), radius: radius)
        await monitor.add(condition, identifier: Self.fenceIdentifier, assuming: .satisfied)
    }

    func removeFence() async {
        await monitor?.remove(Self.fenceIdentifier)
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
