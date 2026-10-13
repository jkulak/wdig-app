import Foundation

/// The thresholds the segmenter runs on. Settings, not constants: raw points are kept for
/// ever, so a changed value applies to new segments at once and to past days through a re-run.
struct SegmentationSettings: Codable, Sendable, Equatable {
    /// A stop is at least this long within this radius of the window's running median.
    var stopRadiusM: Double = 75
    var stopMinDuration: Double = 300
    /// Consecutive trip fixes farther apart in time than this are joined by a dotted leg.
    var gapTime: Double = 180
    /// The speed tie-breaker's bands, in metres per second.
    var walkMaxMps: Double = 2.2
    var runMaxMps: Double = 4.0
    var cycleMaxMps: Double = 9.0
    /// Steps per minute from which walking is running.
    var cadenceRunSpm: Double = 140
    /// A train: automotive, the 90th-percentile speed over this, and the median course change under this.
    var trainSpeedKmh: Double = 130
    var trainStraightnessDeg: Double = 5
    /// A plane: the 90th-percentile speed over this, or two stops this far apart with nothing between.
    var planeSpeedKmh: Double = 200
    var planeMinDistanceKm: Double = 100

    static let key = "segmentation.settings"

    static func load(from defaults: UserDefaults = .standard) -> SegmentationSettings {
        guard let data = defaults.data(forKey: key),
            let settings = try? JSONDecoder().decode(SegmentationSettings.self, from: data)
        else { return SegmentationSettings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
