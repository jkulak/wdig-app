import Foundation

/// A made-up month to look at before the recorder has one, over real streets: the routes
/// come from Apple Maps directions between real places (`DemoRoutes.json`, written by
/// `scripts/demo-routes.swift`), and the points along them are sampled the way the recorder
/// keeps fixes: 10 m on foot, 25 m on a bike, 50 m in a car or every 60 s, with the first
/// hundred metres from the door missing, GPS noise and a stop's few warm-phase fixes. The
/// backend's `wdig seed` reads the same file, so a phone and a server tell the same story.
enum DemoMonth {
    static let deviceId = UUID(uuidString: "00000000-0000-7000-8000-00000000de00") ?? UUID()
    static let doorGapM: Double = 120

    enum Mode: String {
        case walk
        case run
        case bike
        case car

        var speed: Double {
            switch self {
            case .walk: 1.4
            case .run: 2.9
            case .bike: 5.5
            case .car: 9.0
            }
        }

        var spacing: Double {
            switch self {
            case .walk, .run: 10
            case .bike: 25
            case .car: 50
            }
        }

        var noise: Double {
            self == .car ? 6 : 3
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

        /// The leg to route on: runs follow the walking routes.
        var legMode: String {
            self == .run ? "walk" : rawValue
        }
    }

    struct Day {
        var points: [PointSample]
        var segments: [SegmentSnapshot]
    }

    /// Writes `days` days ending yesterday and returns a line for the screen.
    static func generate(into store: RecorderStore, days: Int = 30, seed: UInt64 = 1) async throws -> String {
        let routes = try DemoRoutes.load()
        _ = try await remove(from: store)
        let tz = TimeZone.current.identifier
        var generator = SeededGenerator(seed: seed)
        var pointCount = 0
        var segmentCount = 0
        let today = LocalDay.key(for: Date(), tz: tz)
        guard let todayStart = LocalDay.bounds(of: today, tz: tz)?.start else { return "no day" }
        for offset in stride(from: days, through: 1, by: -1) {
            let date = LocalDay.key(for: todayStart.addingTimeInterval(TimeInterval(-offset) * 86_400 + 3_600), tz: tz)
            let day = makeDay(date, tz: tz, routes: routes, using: &generator)
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

    // MARK: - The plan of a day

    struct Visit {
        let place: String
        let mode: Mode
        let stay: TimeInterval
    }

    /// Where the day goes, in order, by the weekday and the dice; the day starts and ends at home.
    static func plan(weekend: Bool, using generator: inout SeededGenerator) -> (
        departure: TimeInterval, visits: [Visit]
    ) {
        var visits: [Visit] = []
        if weekend {
            let roll = generator.unit()
            if roll < 0.3 {
                visits += [
                    Visit(place: "vistula", mode: .bike, stay: 5 * 60),
                    Visit(place: "lomianki", mode: .bike, stay: 45 * 60),
                    Visit(place: "vistula", mode: .bike, stay: 10 * 60), Visit(place: "home", mode: .bike, stay: 0),
                ]
            } else if roll < 0.55 {
                visits += [
                    Visit(place: "oldTown", mode: .walk, stay: 90 * 60), Visit(place: "home", mode: .walk, stay: 0),
                ]
            } else if roll < 0.75 {
                visits += [
                    Visit(place: "zloteTarasy", mode: .walk, stay: 100 * 60),
                    Visit(place: "home", mode: .walk, stay: 0),
                ]
            } else if roll < 0.9 {
                visits += [
                    Visit(place: "lazienki", mode: .run, stay: 4 * 60), Visit(place: "home", mode: .run, stay: 0),
                ]
            } else {
                visits += [
                    Visit(place: "vistula", mode: .walk, stay: 40 * 60), Visit(place: "home", mode: .walk, stay: 0),
                ]
            }
            visits.append(Visit(place: "home", mode: .walk, stay: (60 + generator.unit() * 60) * 60))
            if generator.unit() < 0.4 {
                if generator.unit() < 0.5 {
                    visits += [
                        Visit(place: "kinoteka", mode: .walk, stay: 150 * 60),
                        Visit(place: "home", mode: .walk, stay: 0),
                    ]
                } else {
                    visits += [
                        Visit(place: "koszyki", mode: .walk, stay: 60 * 60), Visit(place: "home", mode: .walk, stay: 0),
                    ]
                }
            }
            return (10 * 3_600 + (generator.unit() * 60 - 30) * 60, visits)
        }
        visits += [
            Visit(place: "office", mode: .car, stay: (8 * 60 + 20 + generator.unit() * 60 - 30) * 60),
            Visit(place: "home", mode: .car, stay: (45 + generator.unit() * 45) * 60),
        ]
        let roll = generator.unit()
        if roll < 0.3 {
            visits += [Visit(place: "vistula", mode: .walk, stay: 25 * 60), Visit(place: "home", mode: .walk, stay: 0)]
        } else if roll < 0.5 {
            visits += [Visit(place: "lazienki", mode: .run, stay: 4 * 60), Visit(place: "home", mode: .run, stay: 0)]
        } else if roll < 0.65 {
            visits += [
                Visit(place: "kinoteka", mode: .walk, stay: 150 * 60), Visit(place: "home", mode: .walk, stay: 0),
            ]
        } else if roll < 0.8 {
            visits += [Visit(place: "koszyki", mode: .walk, stay: 50 * 60), Visit(place: "home", mode: .walk, stay: 0)]
        }
        return (7 * 3_600 + 50 * 60 + (generator.unit() * 30 - 15) * 60, visits)
    }

    static func makeDay(_ day: String, tz: String, routes: DemoRoutes, using generator: inout SeededGenerator) -> Day {
        guard let bounds = LocalDay.bounds(of: day, tz: tz) else { return Day(points: [], segments: []) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: tz) ?? .gmt
        let weekday = calendar.component(.weekday, from: bounds.start.addingTimeInterval(3_600))
        let (departure, visits) = plan(weekend: weekday == 1 || weekday == 7, using: &generator)
        var points: [PointSample] = []
        var segments: [SegmentSnapshot] = []
        var now = bounds.start.addingTimeInterval(departure)
        var here = "home"
        let first = stay(at: routes.place("home"), from: bounds.start, to: now, tz: tz, using: &generator)
        points += first.points
        segments.append(first.segment)
        for visit in visits {
            if visit.place != here {
                guard let leg = routes.leg(from: here, to: visit.place, mode: visit.mode.legMode) else { continue }
                let trip = sample(leg: leg, mode: visit.mode, start: now, tz: tz, using: &generator)
                points += trip.points
                segments.append(trip.segment)
                now = trip.segment.endAt
                here = visit.place
            }
            if visit.stay > 0 {
                let leave = now.addingTimeInterval(visit.stay)
                let pause = stay(at: routes.place(here), from: now, to: leave, tz: tz, using: &generator)
                points += pause.points
                segments.append(pause.segment)
                now = leave
            }
        }
        let last = stay(at: routes.place("home"), from: now, to: bounds.end, tz: tz, using: &generator)
        points += last.points
        segments.append(last.segment)
        return Day(points: points, segments: segments)
    }

    // MARK: - Points along a route and at a stop

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

    /// Walks the leg's polyline at the mode's speed, keeping a fix every `spacing` metres or 60 s
    /// as the recorder would, after the first `doorGapM` metres the recorder misses.
    static func sample(leg: DemoRoutes.Leg, mode: Mode, start: Date, tz: String, using generator: inout SeededGenerator)
        -> (points: [PointSample], segment: SegmentSnapshot)
    {
        var points: [PointSample] = []
        var time = start
        var travelled = 0.0
        var sinceLastKept = -doorGapM
        var lastKeptAt = start
        var speed = mode.speed
        var stretchLeft = 0.0
        var recording = false
        let coordinates = leg.coordinates
        func keep(_ spot: Coordinate, speed: Double, course: Double) {
            let noisy = spot.offset(
                north: generator.unit() * 2 * mode.noise - mode.noise,
                east: generator.unit() * 2 * mode.noise - mode.noise)
            var sample = PointSample(
                deviceId: deviceId, recordedAt: time, tz: tz, latitude: noisy.latitude, longitude: noisy.longitude,
                hAccM: Int16(4 + generator.next() % 12))
            sample.speedCms = Int16((speed * 100).rounded())
            sample.courseDeg = Int16(course.rounded()) % 360
            sample.activity = mode.activity
            sample.activityConf = generator.unit() < 0.85 ? 2 : 1
            points.append(sample)
            lastKeptAt = time
            sinceLastKept = 0
        }
        for index in 1..<coordinates.count {
            let from = coordinates[index - 1]
            let to = coordinates[index]
            let length = from.distance(to: to)
            let course = from.bearing(to: to)
            var along = 0.0
            while along < length {
                if stretchLeft <= 0 {
                    speed = mode.speed * (0.8 + generator.unit() * 0.4)
                    stretchLeft = 150 + generator.unit() * 150
                }
                let step = min(mode.spacing - max(sinceLastKept, 0), stretchLeft, length - along)
                along += step
                travelled += step
                stretchLeft -= step
                sinceLastKept += step
                time = time.addingTimeInterval(step / speed)
                let spot = from.offset(north: along * cos(course * .pi / 180), east: along * sin(course * .pi / 180))
                if !recording, sinceLastKept >= 0 {
                    // The door gap is over: the recorder has its first fix from here on.
                    recording = true
                    lastKeptAt = time
                }
                if recording, sinceLastKept >= mode.spacing || time.timeIntervalSince(lastKeptAt) >= 60 {
                    keep(spot, speed: speed, course: course)
                }
            }
            // A red light now and then in a car: the recorder keeps a point after a minute of standing.
            if mode == .car, index < coordinates.count - 1, generator.unit() < 0.12 {
                let pause = 15 + generator.unit() * 60
                time = time.addingTimeInterval(pause)
                if pause >= 60 {
                    keep(to, speed: 0, course: course)
                }
            }
        }
        if let last = coordinates.last, sinceLastKept > 0 {
            keep(last, speed: speed, course: points.last.map { Double($0.courseDeg) } ?? 0)
        }
        let steps: Int32? =
            switch mode {
            case .walk: Int32(travelled / 0.75)
            case .run: Int32(travelled / 1.1)
            default: nil
            }
        var segment = SegmentSnapshot(
            kind: "trip", startAt: start, endAt: time, tz: tz, modeDetected: mode.detected, modeConf: "high",
            modeType: mode.rawValue,
            distanceM: Int32(travelled.rounded()), pointCount: Int32(points.count))
        segment.steps = steps
        segment.deviceId = deviceId
        return (points, segment)
    }
}

/// The street routes and places of the demo month, from `DemoRoutes.json`.
struct DemoRoutes: Decodable {
    struct Place: Decodable {
        let name: String
        let lat: Double
        let lon: Double
    }

    struct Leg: Decodable {
        let from: String
        let to: String
        let mode: String
        let distanceM: Int
        let coordinates: [Coordinate]

        enum CodingKeys: String, CodingKey {
            case from, to, mode, distanceM, coordinates
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            from = try container.decode(String.self, forKey: .from)
            to = try container.decode(String.self, forKey: .to)
            mode = try container.decode(String.self, forKey: .mode)
            distanceM = try container.decode(Int.self, forKey: .distanceM)
            let pairs = try container.decode([[Double]].self, forKey: .coordinates)
            coordinates = pairs.compactMap { $0.count == 2 ? Coordinate(latitude: $0[0], longitude: $0[1]) : nil }
        }
    }

    let places: [String: Place]
    let legs: [String: Leg]

    static func load() throws -> DemoRoutes {
        guard let url = Bundle.main.url(forResource: "DemoRoutes", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(DemoRoutes.self, from: Data(contentsOf: url))
    }

    func place(_ key: String) -> Coordinate {
        guard let place = places[key] else { return Coordinate(latitude: 52.2288, longitude: 21.0168) }
        return Coordinate(latitude: place.lat, longitude: place.lon)
    }

    func leg(from: String, to: String, mode: String) -> Leg? {
        legs["\(from)-\(to)-\(mode)"]
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
