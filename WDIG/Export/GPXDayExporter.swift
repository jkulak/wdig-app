import Foundation
import UniformTypeIdentifiers

/// One local day as GPX 1.1, the form every map tool reads: one track for the day with a
/// segment per trip, a waypoint per stop, and WDIG's own fields in the `wdig:` namespace so
/// the file stays valid for every reader and loses nothing for ours. The server's export
/// writes the same layout.
enum GPXDayExporter {
    static let namespace = "https://wdig.itsnotezra.com/gpx/1"
    static let creator = "WDIG \(DeviceInfo.appVersion)"

    /// Writes the day's file into the temporary directory and returns it.
    static func export(day: String, tz: String, store: RecorderStore) async throws -> URL {
        let document = try await document(day: day, tz: tz, store: store)
        let url = FileManager.default.temporaryDirectory.appending(path: "wdig-\(day).gpx")
        try document.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func document(day: String, tz: String, store: RecorderStore, now: Date = Date()) async throws -> String {
        guard let bounds = LocalDay.bounds(of: day, tz: tz) else { throw CocoaError(.fileNoSuchFile) }
        let segments = try await store.segments(overlappingDay: day, tz: tz).filter { $0.computedBy == "phone" }
        let from = min(bounds.start, segments.map(\.startAt).min() ?? bounds.start)
        // The store's range is half-open; a second past the last end keeps the last fix in.
        let to = max(bounds.end, segments.map(\.endAt).max() ?? bounds.end).addingTimeInterval(1)
        let points = try await store.points(from: from, to: to).filter { $0.hAccM <= 100 }
        let algorithmVersion = segments.map(\.algorithmVersion).max() ?? Segmenter.algorithmVersion
        return render(
            day: day, tz: tz, segments: segments, points: points, algorithmVersion: algorithmVersion, now: now)
    }

    static func render(
        day: String, tz: String, segments: [SegmentSnapshot], points: [PointSample], algorithmVersion: Int16, now: Date
    ) -> String {
        var out = XMLOut()
        out.line(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        out.line(
            #"<gpx version="1.1" creator="\#(XMLOut.escape(creator))" xmlns="http://www.topografix.com/GPX/1/1" xmlns:wdig="\#(namespace)">"#
        )
        let coarse = segments.contains { $0.coarse } || points.contains { $0.coarse }
        let stops = segments.filter { $0.kind == "stop" }.sorted { $0.startAt < $1.startAt }
        let trips = segments.filter { $0.kind == "trip" }.sorted { $0.startAt < $1.startAt }
        let exported = points.filter { point in
            trips.contains { point.recordedAt >= $0.startAt && point.recordedAt <= $0.endAt }
        }
        let bounded = exported.map(\.coordinate) + stops.compactMap(\.center)
        out.open("metadata")
        out.element("name", "WDIG \(day)")
        out.element("time", XMLOut.time(now))
        if let box = box(of: bounded) {
            out.line(
                #"<bounds minlat="\#(box.minLat)" minlon="\#(box.minLon)" maxlat="\#(box.maxLat)" maxlon="\#(box.maxLon)"/>"#
            )
        }
        out.open("extensions")
        out.element("wdig:tz", tz)
        out.element("wdig:coarse", coarse ? "true" : "false")
        out.element("wdig:algorithm_version", String(algorithmVersion))
        out.close("extensions")
        out.close("metadata")
        for stop in stops {
            guard let center = stop.center else { continue }
            out.line(#"<wpt lat="\#(XMLOut.degrees(center.latitude))" lon="\#(XMLOut.degrees(center.longitude))">"#)
            out.element("time", XMLOut.time(stop.startAt))
            let span = "\(XMLOut.clock(stop.startAt, tz: tz))\u{2013}\(XMLOut.clock(stop.endAt, tz: tz))"
            out.element("name", "\(String(localized: "Stop")) \(span)")
            out.element("desc", DayMapModel.dwell(stop.endAt.timeIntervalSince(stop.startAt)))
            out.open("extensions")
            out.element("wdig:segment_id", stop.id.uuidString.lowercased())
            out.element("wdig:kind", "stop")
            out.element("wdig:end_at", XMLOut.time(stop.endAt))
            out.close("extensions")
            out.line("</wpt>")
        }
        out.open("trk")
        out.element("name", day)
        for trip in trips where trip.pointCount > 0 {
            let inside = exported.filter { $0.recordedAt >= trip.startAt && $0.recordedAt <= trip.endAt }
            guard !inside.isEmpty else { continue }
            out.open("trkseg")
            for point in inside {
                out.line(#"<trkpt lat="\#(XMLOut.degrees(point.latitude))" lon="\#(XMLOut.degrees(point.longitude))">"#)
                if let altM = point.altM {
                    out.element("ele", String(altM))
                }
                out.element("time", XMLOut.time(point.recordedAt))
                out.open("extensions")
                out.element("wdig:h_acc_m", String(point.hAccM))
                if point.speedCms >= 0 {
                    out.element("wdig:speed_cms", String(point.speedCms))
                }
                if point.courseDeg >= 0 {
                    out.element("wdig:course_deg", String(point.courseDeg))
                }
                out.element("wdig:activity", String(point.activity))
                out.element("wdig:activity_conf", String(point.activityConf))
                out.close("extensions")
                out.line("</trkpt>")
            }
            out.open("extensions")
            out.element("wdig:segment_id", trip.id.uuidString.lowercased())
            out.element("wdig:mode_type", trip.modeType)
            out.element("wdig:mode_detected", trip.modeDetected)
            out.element("wdig:mode_conf", trip.modeConf)
            out.element("wdig:distance_m", String(trip.distanceM))
            out.element("wdig:start_at", XMLOut.time(trip.startAt))
            out.element("wdig:end_at", XMLOut.time(trip.endAt))
            out.close("extensions")
            out.close("trkseg")
        }
        out.close("trk")
        out.line("</gpx>")
        return out.text
    }

    static func box(of coordinates: [Coordinate]) -> (minLat: String, minLon: String, maxLat: String, maxLon: String)? {
        guard let first = coordinates.first else { return nil }
        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude
        for coordinate in coordinates {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }
        return (XMLOut.degrees(minLat), XMLOut.degrees(minLon), XMLOut.degrees(maxLat), XMLOut.degrees(maxLon))
    }

    /// Removes the files earlier exports left in the temporary directory.
    static func cleanUp() {
        let directory = FileManager.default.temporaryDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix("wdig-") && name.hasSuffix(".gpx") {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }
}

/// A small XML writer: lines, elements with escaped text, no library.
struct XMLOut {
    private(set) var text = ""
    private var depth = 0

    mutating func line(_ line: String) {
        text += String(repeating: " ", count: depth * 2) + line + "\n"
    }

    mutating func open(_ name: String) {
        line("<\(name)>")
        depth += 1
    }

    mutating func close(_ name: String) {
        depth -= 1
        line("</\(name)>")
    }

    mutating func element(_ name: String, _ value: String) {
        line("<\(name)>\(Self.escape(value))</\(name)>")
    }

    static func escape(_ value: String) -> String {
        var out = ""
        for character in value {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(character)
            }
        }
        return out
    }

    static func degrees(_ value: Double) -> String {
        String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func time(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    static func clock(_ date: Date, tz: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: tz) ?? .gmt
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

extension UTType {
    static let gpx = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
}
