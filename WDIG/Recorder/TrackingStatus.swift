import Foundation

/// What the banner says: one line from the recorder's state, the permission, the power and
/// the last fix, decided by a pure function so every state has a test.
enum TrackingStatus: Equatable, Sendable {
    enum CoarseReason: Equatable, Sendable {
        case lowPowerMode
        case battery(percent: Int16?)
    }

    case off
    case needsAlways
    case denied
    case on(lastFixAt: Date?)
    case coarse(CoarseReason)
    case gap(Gap)

    static func make(
        trackingEnabled: Bool, authorization: String, phase: LocationRecorder.Phase, power: PowerSnapshot,
        lastFixAt: Date?, openGap: Gap?
    ) -> TrackingStatus {
        guard trackingEnabled else { return .off }
        switch authorization {
        case "denied", "restricted": return .denied
        case "whenInUse", "notDetermined": return .needsAlways
        default: break
        }
        if let openGap { return .gap(openGap) }
        if phase == .coarse {
            return .coarse(power.lowPowerMode ? .lowPowerMode : .battery(percent: power.levelPercent))
        }
        return .on(lastFixAt: lastFixAt)
    }
}

/// A stretch of a day with no fixes where there should have been some.
struct Gap: Equatable, Sendable, Codable, Hashable {
    var from: Date
    var to: Date
}

/// What makes a hole a gap. Settings rather than constants, so the measurement can move
/// them without a build; the brief fixes only the two hours.
struct GapSettings: Codable, Sendable, Equatable {
    var gapHours: Double = 2
    var daytimeStart: Int = 7
    var daytimeEnd: Int = 23

    static let key = "gap.settings"

    static func load(from defaults: UserDefaults = .standard) -> GapSettings {
        guard let data = defaults.data(forKey: key),
            let settings = try? JSONDecoder().decode(GapSettings.self, from: data)
        else { return GapSettings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

/// A gap is a stretch longer than `gapHours` with no kept point and no recorder event that
/// lies at least partly in daytime, after a moment that promised more: a hole through the
/// night is sleep, and silence after the recorder went to sleep behind a fence, dropped to
/// coarse mode or was switched off is what was asked for, not a failure.
enum GapDetector {
    struct Moment: Sendable, Equatable {
        var at: Date
        /// True after an event that leaves the recorder quiet on purpose.
        var silenceExpected = false

        init(_ at: Date, silenceExpected: Bool = false) {
            self.at = at
            self.silenceExpected = silenceExpected
        }
    }

    /// The gaps between consecutive moments, and from the last moment to `now`.
    static func gaps(moments: [Moment], now: Date, tz: String, settings: GapSettings = GapSettings()) -> [Gap] {
        let sorted = (moments + [Moment(now)]).sorted { $0.at < $1.at }
        var gaps: [Gap] = []
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            guard !a.silenceExpected, b.at.timeIntervalSince(a.at) > settings.gapHours * 3_600 else { continue }
            if touchesDaytime(from: a.at, to: b.at, tz: tz, settings: settings) {
                gaps.append(Gap(from: a.at, to: b.at))
            }
        }
        return gaps
    }

    static func touchesDaytime(from start: Date, to end: Date, tz: String, settings: GapSettings = GapSettings())
        -> Bool
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: tz) ?? .gmt
        func daytime(_ date: Date) -> Bool {
            let hour = calendar.component(.hour, from: date)
            return hour >= settings.daytimeStart && hour < settings.daytimeEnd
        }
        var cursor = start
        while cursor < end {
            if daytime(cursor) { return true }
            guard let next = calendar.date(byAdding: .hour, value: 1, to: cursor) else { break }
            cursor = next
        }
        return daytime(end)
    }
}

/// Which gaps have been seen and which dismissed, so each is logged once and a dismissal
/// holds. A gap is known by its start; its end moves while it is still open.
struct GapTracker: Codable, Sendable, Equatable {
    static let key = "gap.tracker"
    static let keptDays = 7

    var detected: [Gap] = []
    var dismissed: [Date] = []

    /// Records the gaps found now and returns the ones seen for the first time.
    mutating func update(with gaps: [Gap], now: Date) -> [Gap] {
        var fresh: [Gap] = []
        for gap in gaps {
            if let index = detected.firstIndex(where: { $0.from == gap.from }) {
                detected[index].to = gap.to
            } else {
                detected.append(gap)
                fresh.append(gap)
            }
        }
        let cutoff = now.addingTimeInterval(-Double(Self.keptDays) * 86_400)
        detected.removeAll { $0.from < cutoff }
        dismissed.removeAll { $0 < cutoff }
        return fresh
    }

    /// The newest gap not yet dismissed.
    var open: Gap? {
        detected.filter { !dismissed.contains($0.from) }.max { $0.from < $1.from }
    }

    mutating func dismiss() -> Gap? {
        guard let gap = open else { return nil }
        dismissed.append(gap.from)
        return gap
    }

    static func load(from defaults: UserDefaults = .standard) -> GapTracker {
        guard let data = defaults.data(forKey: key),
            let tracker = try? JSONDecoder().decode(GapTracker.self, from: data)
        else { return GapTracker() }
        return tracker
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
