import Foundation

/// The numbers the recorder runs on. They are settings, not constants, so the battery
/// measurement can tune them without a build; the defaults are the design's.
struct RecorderSettings: Codable, Sendable, Equatable {
    /// How long the low-accuracy warm phase runs after a detected stop before updates go off.
    var warmPhaseSeconds: Double = 600
    /// A fix farther than this from the stop's reference means the stop is over.
    var stopRadiusM: Double = 75
    /// The geofence around a stop that wakes the recorder when left.
    var fenceRadiusM: Double = 150
    /// Thinning: the least distance between kept fixes on foot, on a bike and in a vehicle.
    var thinFootM: Double = 10
    var thinCycleM: Double = 25
    var thinVehicleM: Double = 50
    /// Thinning: a fix is kept after this many seconds whatever the distance.
    var thinSeconds: Double = 60
    /// How long a speed has to hold before the live configuration switches.
    var classHoldSeconds: Double = 60
    /// The window of kept fixes whose median is the reference of a stop.
    var referenceWindowSeconds: Double = 300

    static let key = "recorder.settings"

    static func load(from defaults: UserDefaults = .standard) -> RecorderSettings {
        guard let data = defaults.data(forKey: key),
            let settings = try? JSONDecoder().decode(RecorderSettings.self, from: data)
        else { return RecorderSettings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
