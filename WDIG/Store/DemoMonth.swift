import Foundation

/// A made-up month to look at before the recorder has one: weekdays to work and back, an
/// evening walk now and then, weekends with a long walk, a ride or a drive, all around a home.
/// Deterministic, under a device id of its own so it can be removed whole. The same life as
/// the backend's `wdig seed`, so a phone and a server tell the same story.
enum DemoMonth {
    static let deviceId = UUID(uuidString: "00000000-0000-7000-8000-00000000de00") ?? UUID()
    static let home = Coordinate(latitude: 52.2297, longitude: 21.0122)

    enum Mode: CaseIterable {
        case walk
        case run
        case bike
        case car

        var speed: Double {
            switch self {
            case .walk: 1.4
            case .run: 2.9
            case .bike: 5.5
            case .car: 11.0
            }
        }

        var spacing: Double {
            switch self {
            case .walk, .run: 10
            case .bike: 25
            case .car: 50
            }
        }

        var activity: Int16 {
            switch self {
            case .walk: 2
            case .run: 3
            case .bike: 4
            case .car: 5
            }
        }

        var detected: String {
            switch self {
            case .walk: "walking"
            case .run: "running"
            case .bike: "cycling"
            case .car: "automotive"
            }
        }

        var type: String {
            switch self {
            case .walk: "walk"
            case .run: "run"
            case .bike: "bike"
            case .car: "car"
            }
        }
    }

    struct Day {
        var points: [PointSample]
        var segments: [SegmentSnapshot]
    }

    /// Writes `days` days ending yesterday and returns a line for the screen.
    static func generate(into store: RecorderStore, days: Int = 30, home: Coordinate = home, seed: UInt64 = 1)
        async throws
        -> String
    {
        try await remove(from: store)
        let tz = TimeZone.current.identifier
        var generator = SeededGenerator(seed: seed)
        var pointCount = 0
        var segmentCount = 0
        let today = LocalDay.key(for: Date(), tz: tz)
        for offset in stride(from: days, through: 1, by: -1) {
            guard let todayStart = LocalDay.bounds(of: today, tz: tz)?.start else { break }
            let date = LocalDay.key(for: todayStart.addingTimeInterval(TimeInterval(-offset) * 86_400 + 3_600), tz: tz)
            let day = makeDay(date, tz: tz, home: home, using: &generator)
            try await store.append(day.points)
            for segment in day.segments {
                try await store.upsert(segment)
            }
            pointCount += day.points.count
            segmentCount += day.segments.count
        }
        return "\(days) days, \(pointCount) points, \(segmentCount) segments"
    }

    static func remove(from store: RecorderStore) async throws -> String {
        let removed = try await store.deleteEverything(ofDevice: deviceId)
        return "removed \(removed.points) points and \(removed.segments) segments"
    }

    // MARK: - One day

    struct Places {
        let home: Coordinate
        let work: Coordinate
        let gym: Coordinate
        let shop: Coordinate
        let park: Coordinate
        let lake: Coordinate

        init(home: Coordinate) {
            self.home = home
            work = home.offset(north: 2_100, east: 2_400)
            gym = home.offset(north: -900, east: 1_100)
            shop = home.offset(north: 500, east: -600)
            park = home.offset(north: 1_500, east: -1_200)
            lake = home.offset(north: -18_000, east: 16_000)
        }
    }

    static func makeDay(_ day: String, tz: String, home: Coordinate, using generator: inout SeededGenerator) -> Day {
        guard let bounds = LocalDay.bounds(of: day, tz: tz) else { return Day(points: [], segments: []) }
        let places = Places(home: home)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: tz) ?? .gmt
        let weekday = calendar.component(.weekday, from: bounds.start.addingTimeInterval(3_600))
        let weekend = weekday == 1 || weekday == 7
        var plan: [(Coordinate, Mode, TimeInterval)] = []
        if weekend {
            switch Int(generator.next() % 4) {
            case 0: plan.append((places.park, .walk, 25 * 60))
            case 1: plan.append((places.lake, .car, 150 * 60))
            case 2:
                plan.append((places.park, .bike, 10 * 60))
                plan.append((places.lake, .bike, 60 * 60))
            default: plan.append((places.park, .run, 5 * 60))
            }
            plan.append((places.shop, .walk, 20 * 60))
        } else {
            let commute: Mode = generator.unit() < 0.6 ? .bike : .car
            plan.append((places.work, commute, TimeInterval(505 + Int(generator.next() % 80) - 40) * 60))
            if generator.unit() < 0.4 { plan.append((places.gym, .walk, 70 * 60)) }
            if generator.unit() < 0.5 { plan.append((places.shop, .walk, 15 * 60)) }
        }
        plan.append((places.home, weekend ? .walk : plan[0].1, 0))

        var points: [PointSample] = []
        var segments: [SegmentSnapshot] = []
        let departureHour: TimeInterval = weekend ? 9.5 : 7.75
        var now = bounds.start.addingTimeInterval(
            departureHour * 3_600 + TimeInterval(Int(generator.next() % 40) - 20) * 60)
        var here = places.home
        let firstStay = stay(at: places.home, from: bounds.start, to: now, tz: tz, using: &generator)
        points += firstStay.points
        segments.append(firstStay.segment)
        for (destination, mode, minutes) in plan {
            let leg = trip(from: here, to: destination, mode: mode, start: now, tz: tz, using: &generator)
            points += leg.points
            segments.append(leg.segment)
            now = leg.segment.endAt
            here = destination
            if minutes > 0 {
                let leave = now.addingTimeInterval(minutes)
                let pause = stay(at: here, from: now, to: leave, tz: tz, using: &generator)
                points += pause.points
                segments.append(pause.segment)
                now = leave
            }
        }
        let lastStay = stay(at: places.home, from: now, to: bounds.end, tz: tz, using: &generator)
        points += lastStay.points
        segments.append(lastStay.segment)
        return Day(points: points, segments: segments)
    }

    static func stay(
        at place: Coordinate, from start: Date, to end: Date, tz: String, using generator: inout SeededGenerator
    )
        -> (points: [PointSample], segment: SegmentSnapshot)
    {
        var points: [PointSample] = []
        let count = 3 + Int(generator.next() % 4)
        for index in 0..<count {
            let spot = place.offset(north: generator.unit() * 40 - 20, east: generator.unit() * 40 - 20)
            var sample = PointSample(
                deviceId: deviceId, recordedAt: start.addingTimeInterval(30 + TimeInterval(index) * 100), tz: tz,
                latitude: spot.latitude, longitude: spot.longitude, hAccM: Int16(20 + generator.next() % 60))
            sample.speedCms = 0
            sample.activity = 1
            sample.activityConf = 2
            points.append(sample)
        }
        let segment = SegmentSnapshot(
            kind: "stop", startAt: start, endAt: end, tz: tz, modeDetected: "stationary", modeConf: "high",
            modeType: "other",
            pointCount: Int32(count), centerLat: PointSample.scaled(place.latitude),
            centerLon: PointSample.scaled(place.longitude))
        return (points, segment)
    }

    static func trip(
        from: Coordinate, to: Coordinate, mode: Mode, start: Date, tz: String, using generator: inout SeededGenerator
    )
        -> (points: [PointSample], segment: SegmentSnapshot)
    {
        let straight = max(from.distance(to: to), 50)
        let bend = straight * 0.12
        let bearing = from.bearing(to: to) * .pi / 180
        func side(_ along: Double, _ off: Double) -> Coordinate {
            from.offset(
                north: along * cos(bearing) - off * sin(bearing), east: along * sin(bearing) + off * cos(bearing))
        }
        let first = side(straight * 0.33, generator.unit() * 2 * bend - bend)
        let second = side(straight * 0.66, generator.unit() * 2 * bend - bend)
        var points: [PointSample] = []
        var at = start
        var distance = 0.0
        for (legStart, legEnd) in [(from, first), (first, second), (second, to)] {
            let length = legStart.distance(to: legEnd)
            let steps = max(1, Int((length / mode.spacing).rounded(.up)))
            let legBearing = legStart.bearing(to: legEnd) * .pi / 180
            for index in 0..<steps {
                let along = Double(index) / Double(steps) * length
                let noise = generator.unit() * 6 - 3
                let spot = legStart.offset(
                    north: along * cos(legBearing) + noise * sin(legBearing),
                    east: along * sin(legBearing) - noise * cos(legBearing))
                let variation = 0.75 + generator.unit() * 0.5
                let speed = (mode == .car && generator.unit() < 0.08) ? 0 : mode.speed * variation
                var sample = PointSample(
                    deviceId: deviceId, recordedAt: at, tz: tz, latitude: spot.latitude, longitude: spot.longitude,
                    hAccM: Int16(4 + generator.next() % 12))
                sample.speedCms = Int16((speed * 100).rounded())
                sample.courseDeg = Int16(legStart.bearing(to: legEnd).rounded()) % 360
                sample.activity = mode.activity
                sample.activityConf = generator.unit() < 0.85 ? 2 : 1
                points.append(sample)
                let step = length / Double(steps)
                distance += step
                at = at.addingTimeInterval(step / max(speed, 0.5) + (speed == 0 ? 20 : 0))
            }
        }
        let steps: Int32? =
            switch mode {
            case .walk: Int32(distance / 0.75)
            case .run: Int32(distance / 1.1)
            default: nil
            }
        var segment = SegmentSnapshot(
            kind: "trip", startAt: start, endAt: at, tz: tz, modeDetected: mode.detected, modeConf: "high",
            modeType: mode.type,
            distanceM: Int32(distance.rounded()), pointCount: Int32(points.count))
        segment.steps = steps
        segment.deviceId = deviceId
        return (points, segment)
    }
}

extension Coordinate {
    func offset(north: Double, east: Double) -> Coordinate {
        Coordinate(
            latitude: latitude + north / 111_320, longitude: longitude + east / (111_320 * cos(latitude * .pi / 180)))
    }

    func bearing(to other: Coordinate) -> Double {
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}

/// SplitMix64: a small deterministic generator, so a demo month is the same on every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A number in 0..<1.
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
