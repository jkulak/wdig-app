import CryptoKit
import Foundation

/// A stop or a trip as the segmenter found it, with the points it used, before it becomes a
/// row of the store.
struct SegmentDraft: Sendable, Equatable {
    var kind: String
    var startAt: Date
    var endAt: Date
    var tz: String
    var modeDetected: String
    var modeConf: String
    var modeType: String
    var distanceM: Int32
    var pointCount: Int32
    var centerLat: Int32?
    var centerLon: Int32?
    var source: String
    var coarse: Bool
    var points: [PointSample]

    var center: Coordinate? {
        guard let centerLat, let centerLon else { return nil }
        return Coordinate(
            latitude: Double(centerLat) / PointSample.scale, longitude: Double(centerLon) / PointSample.scale)
    }

    /// The same segment gets the same id on every run, so a re-run replaces rather than doubles.
    func stableId(deviceId: UUID) -> UUID {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: deviceId.uuid) { Array($0) })
        data.append(contentsOf: Array(kind.utf8))
        data.append(contentsOf: withUnsafeBytes(of: startAt.timeIntervalSince1970.bitPattern) { Array($0) })
        let digest = Array(SHA256.hash(data: data).prefix(16))
        var bytes = digest
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9],
                bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    func snapshot(deviceId: UUID, steps: Int32?, now: Date = Date()) -> SegmentSnapshot {
        var snapshot = SegmentSnapshot(
            id: stableId(deviceId: deviceId), kind: kind, startAt: startAt, endAt: endAt, tz: tz,
            modeDetected: modeDetected, modeConf: modeConf, modeType: modeType, distanceM: distanceM,
            pointCount: pointCount, centerLat: centerLat, centerLon: centerLon,
            algorithmVersion: Segmenter.algorithmVersion, coarse: coarse, updatedAt: now)
        snapshot.deviceId = deviceId
        snapshot.source = source
        snapshot.steps = steps
        return snapshot
    }
}

/// One piece of a trip's drawing: solid along the fixes, dotted where the recorder had none.
struct Leg: Sendable, Equatable {
    var from: Coordinate
    var to: Coordinate
    var dotted: Bool
}

/// Method A: stops, trips and modes from the raw points, as a pure function. The server
/// computes the same with the same thresholds; raw points are kept, so both can run again.
enum Segmenter {
    static let algorithmVersion: Int16 = 1
    static let accuracyMaxM: Int16 = 100

    /// `cadence` answers steps per minute for a trip's range, when the pedometer knows it.
    static func segment(
        _ input: [PointSample], settings: SegmentationSettings = SegmentationSettings(),
        cadence: (Date, Date) -> Double? = { _, _ in nil }
    ) -> [SegmentDraft] {
        let points = input.filter { $0.hAccM <= accuracyMaxM }.sorted { $0.recordedAt < $1.recordedAt }
        guard !points.isEmpty else { return [] }
        let stops = findStops(points, settings: settings)
        var drafts: [SegmentDraft] = []
        var cursor = 0
        var previousStop: (draft: SegmentDraft, lastIndex: Int)?
        for stop in stops {
            let between = Array(points[cursor..<stop.firstIndex])
            let start = previousStop?.draft.endAt ?? points[cursor].recordedAt
            if let trip = trip(
                between, from: start, to: stop.draft.startAt, after: previousStop?.draft, before: stop.draft,
                settings: settings, cadence: cadence)
            {
                drafts.append(trip)
            }
            drafts.append(stop.draft)
            cursor = stop.lastIndex + 1
            previousStop = (stop.draft, stop.lastIndex)
        }
        if cursor < points.count {
            let rest = Array(points[cursor...])
            let start = previousStop?.draft.endAt ?? rest[0].recordedAt
            if let trip = trip(
                rest, from: start, to: rest[rest.count - 1].recordedAt, after: previousStop?.draft, before: nil,
                settings: settings, cadence: cadence)
            {
                drafts.append(trip)
            }
        }
        return drafts
    }

    // MARK: - Stops

    private struct FoundStop {
        let draft: SegmentDraft
        let firstIndex: Int
        let lastIndex: Int
    }

    /// A dwell window grows while every point lies within the radius of its running median; a
    /// time gap does not close it, distance alone does. Long enough, it is a stop.
    private static func findStops(_ points: [PointSample], settings: SegmentationSettings) -> [FoundStop] {
        var stops: [FoundStop] = []
        var index = 0
        while index < points.count {
            var window = [points[index]]
            var median = points[index].coordinate
            var last = index
            var next = index + 1
            while next < points.count {
                guard points[next].coordinate.distance(to: median) <= settings.stopRadiusM else { break }
                window.append(points[next])
                median = Coordinate.median(of: window.map(\.coordinate)) ?? median
                last = next
                next += 1
            }
            let duration = points[last].recordedAt.timeIntervalSince(points[index].recordedAt)
            if duration >= settings.stopMinDuration {
                stops.append(FoundStop(draft: stopDraft(window, center: median), firstIndex: index, lastIndex: last))
                index = last + 1
            } else {
                index += 1
            }
        }
        return stops
    }

    private static func stopDraft(_ window: [PointSample], center: Coordinate) -> SegmentDraft {
        SegmentDraft(
            kind: "stop", startAt: window[0].recordedAt, endAt: window[window.count - 1].recordedAt, tz: window[0].tz,
            modeDetected: "stationary", modeConf: "high", modeType: "other", distanceM: 0,
            pointCount: Int32(window.count),
            centerLat: PointSample.scaled(center.latitude), centerLon: PointSample.scaled(center.longitude),
            source: window.allSatisfy { $0.source == "visit" } ? "visit" : "phone",
            coarse: window.contains { $0.coarse },
            points: window)
    }

    // MARK: - Trips

    private static func trip(
        _ points: [PointSample], from start: Date, to end: Date, after previous: SegmentDraft?,
        before next: SegmentDraft?,
        settings: SegmentationSettings, cadence: (Date, Date) -> Double?
    ) -> SegmentDraft? {
        if points.isEmpty {
            // Two stops with nothing between them: a flight when they are far enough apart.
            guard let from = previous?.center, let to = next?.center else { return nil }
            let distance = from.distance(to: to)
            let hours = end.timeIntervalSince(start) / 3_600
            guard distance >= settings.planeMinDistanceKm * 1_000, hours > 0,
                distance / 1_000 / hours > settings.planeSpeedKmh
            else { return nil }
            return SegmentDraft(
                kind: "trip", startAt: start, endAt: end, tz: previous?.tz ?? next?.tz ?? "UTC",
                modeDetected: "unknown",
                modeConf: "low", modeType: "plane", distanceM: Int32(distance.rounded()), pointCount: 0, centerLat: nil,
                centerLon: nil, source: "phone", coarse: previous?.coarse ?? false, points: [])
        }
        var distance = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            distance += a.coordinate.distance(to: b.coordinate)
        }
        let vote = Vote.make(points, start: start, end: end, settings: settings)
        var detected = vote.detected
        if detected == "walking" || detected == "running", let spm = cadence(start, end) {
            detected = spm >= settings.cadenceRunSpm ? "running" : "walking"
        }
        let type = modeType(detected: detected, points: points, settings: settings)
        return SegmentDraft(
            kind: "trip", startAt: start, endAt: end, tz: points[0].tz, modeDetected: detected,
            modeConf: vote.confidence,
            modeType: type, distanceM: Int32(distance.rounded()), pointCount: Int32(points.count), centerLat: nil,
            centerLon: nil, source: "phone", coarse: points.contains { $0.coarse }, points: points)
    }

    struct Vote {
        var detected: String
        var confidence: String

        static let classes: [Int16: String] = [2: "walking", 3: "running", 4: "cycling", 5: "automotive"]

        /// Each point weighs the time to the next one (capped at a minute); the class with the
        /// largest share wins when it reaches half the trip, otherwise the median speed decides.
        static func make(_ points: [PointSample], start: Date, end: Date, settings: SegmentationSettings) -> Vote {
            let duration = max(end.timeIntervalSince(start), 1)
            var weights: [Int16: Double] = [:]
            for (index, point) in points.enumerated() {
                guard classes[point.activity] != nil else { continue }
                let next = index + 1 < points.count ? points[index + 1].recordedAt : end
                weights[point.activity, default: 0] += min(max(next.timeIntervalSince(point.recordedAt), 0), 60)
            }
            if let (code, weight) = weights.max(by: { $0.value < $1.value }), weight / duration >= 0.5,
                let name = classes[code]
            {
                let share = weight / duration
                return Vote(detected: name, confidence: share >= 0.8 ? "high" : "medium")
            }
            let speeds = points.map(\.speedCms).filter { $0 >= 0 }.map { Double($0) / 100 }.sorted()
            guard !speeds.isEmpty else { return Vote(detected: "unknown", confidence: "low") }
            let median = speeds[speeds.count / 2]
            let detected: String
            if median < settings.walkMaxMps {
                detected = "walking"
            } else if median < settings.runMaxMps {
                detected = "running"
            } else if median < settings.cycleMaxMps {
                detected = "cycling"
            } else {
                detected = "automotive"
            }
            return Vote(detected: detected, confidence: "low")
        }
    }

    static func modeType(detected: String, points: [PointSample], settings: SegmentationSettings) -> String {
        let speeds = points.map(\.speedCms).filter { $0 >= 0 }.map { Double($0) / 100 * 3.6 }.sorted()
        let p90 = speeds.isEmpty ? 0 : speeds[min(speeds.count - 1, Int(Double(speeds.count) * 0.9))]
        if p90 > settings.planeSpeedKmh { return "plane" }
        switch detected {
        case "walking": return "walk"
        case "running": return "run"
        case "cycling": return "bike"
        case "automotive":
            if p90 > settings.trainSpeedKmh, let turn = medianCourseChange(points), turn < settings.trainStraightnessDeg
            {
                return "train"
            }
            return "car"
        default: return "other"
        }
    }

    static func medianCourseChange(_ points: [PointSample]) -> Double? {
        let courses = points.map(\.courseDeg).filter { $0 >= 0 }.map(Double.init)
        guard courses.count >= 2 else { return nil }
        let changes = zip(courses, courses.dropFirst()).map { a, b -> Double in
            let d = abs(a - b).truncatingRemainder(dividingBy: 360)
            return min(d, 360 - d)
        }.sorted()
        return changes[changes.count / 2]
    }

    // MARK: - Legs

    /// How a trip is drawn: solid between fixes, dotted where the recorder had none (a gap in
    /// time, the way from the door to the first fix, a flight).
    static func legs(
        for trip: SegmentDraft, after previous: SegmentDraft?, before next: SegmentDraft?,
        settings: SegmentationSettings
    ) -> [Leg] {
        var legs: [Leg] = []
        if trip.points.isEmpty {
            if let from = previous?.center, let to = next?.center {
                legs.append(Leg(from: from, to: to, dotted: true))
            }
            return legs
        }
        if let from = previous?.center, from.distance(to: trip.points[0].coordinate) > settings.stopRadiusM {
            legs.append(Leg(from: from, to: trip.points[0].coordinate, dotted: true))
        }
        for (a, b) in zip(trip.points, trip.points.dropFirst()) {
            legs.append(
                Leg(
                    from: a.coordinate, to: b.coordinate,
                    dotted: b.recordedAt.timeIntervalSince(a.recordedAt) > settings.gapTime))
        }
        if let to = next?.center, let last = trip.points.last, last.coordinate.distance(to: to) > settings.stopRadiusM {
            legs.append(Leg(from: last.coordinate, to: to, dotted: true))
        }
        return legs
    }
}

extension PointSample {
    var coordinate: Coordinate {
        Coordinate(latitude: latitude, longitude: longitude)
    }
}
