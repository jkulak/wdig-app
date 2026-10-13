import Foundation
import Testing

@testable import WDIG

struct GPXExportTests {
    let t0 = Date(timeIntervalSince1970: 1_791_806_400)  // 2026-10-12 12:00 UTC, 14:00 Warsaw
    let device = UUID.v7()

    func makeDay(into store: RecorderStore) async throws -> (
        stopA: SegmentSnapshot, trip: SegmentSnapshot, stopB: SegmentSnapshot
    ) {
        var points: [PointSample] = []
        for index in 0..<30 {
            var sample = PointSample(
                deviceId: device, recordedAt: t0.addingTimeInterval(TimeInterval(index) * 7), tz: "Europe/Warsaw",
                latitude: 52.2288 + Double(index) * 0.0001, longitude: 21.0168, hAccM: index == 10 ? 120 : 8)
            sample.altM = 100
            sample.speedCms = 140
            sample.courseDeg = 0
            sample.activity = 2
            sample.activityConf = 2
            points.append(sample)
        }
        try await store.append(points)
        let stopA = SegmentSnapshot(
            kind: "stop", startAt: t0.addingTimeInterval(-600), endAt: t0, tz: "Europe/Warsaw",
            modeDetected: "stationary",
            modeConf: "high", modeType: "other", centerLat: PointSample.scaled(52.2288),
            centerLon: PointSample.scaled(21.0168))
        let trip = SegmentSnapshot(
            kind: "trip", startAt: t0, endAt: t0.addingTimeInterval(29 * 7), tz: "Europe/Warsaw",
            modeDetected: "walking",
            modeConf: "high", modeType: "walk", distanceM: 320, pointCount: 29)
        let stopB = SegmentSnapshot(
            kind: "stop", startAt: t0.addingTimeInterval(29 * 7), endAt: t0.addingTimeInterval(29 * 7 + 5_100),
            tz: "Europe/Warsaw",
            modeDetected: "stationary", modeConf: "high", modeType: "other", centerLat: PointSample.scaled(52.2317),
            centerLon: PointSample.scaled(21.0168))
        for segment in [stopA, trip, stopB] {
            try await store.upsert(segment)
        }
        return (stopA, trip, stopB)
    }

    @Test("A day exports as one track with a segment per trip and a waypoint per stop, poor fixes left out")
    func dayExportsAsOneTrack() async throws {
        let store = RecorderStore(modelContainer: try Store.container(inMemory: true))
        let day = try await makeDay(into: store)
        let gpx = try await GPXDayExporter.document(day: "2026-10-12", tz: "Europe/Warsaw", store: store, now: t0)
        #expect(gpx.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"WDIG "))
        #expect(
            gpx.contains("xmlns=\"http://www.topografix.com/GPX/1/1\" xmlns:wdig=\"https://wdig.itsnotezra.com/gpx/1\"")
        )
        #expect(gpx.components(separatedBy: "<trk>").count == 2)
        #expect(gpx.components(separatedBy: "<trkseg>").count == 2)
        #expect(gpx.components(separatedBy: "<wpt ").count == 3)
        #expect(
            gpx.components(separatedBy: "<trkpt ").count == 30, "29 kept points: the one with 120 m accuracy is out")
        #expect(gpx.contains("<name>WDIG 2026-10-12</name>"))
        #expect(gpx.contains("<wdig:tz>Europe/Warsaw</wdig:tz>"))
        #expect(gpx.contains("<wdig:mode_type>walk</wdig:mode_type>"))
        #expect(gpx.contains("<wdig:segment_id>\(day.trip.id.uuidString.lowercased())</wdig:segment_id>"))
        #expect(gpx.contains("<name>Stop 13:50\u{2013}14:00</name>"))
        #expect(gpx.contains("<desc>1 h 25 min</desc>"))
        #expect(gpx.contains("<time>2026-10-12T12:00:00Z</time>"))
        #expect(gpx.contains("lat=\"52.2288000\" lon=\"21.0168000\""))
        #expect(gpx.range(of: "<wpt ")!.lowerBound < gpx.range(of: "<trk>")!.lowerBound)
        let parser = XMLParser(data: Data(gpx.utf8))
        #expect(parser.parse())
    }

    @Test("Text is escaped and the file goes to the temporary directory under the day's name")
    func textIsEscapedAndTheFileIsNamedAfterTheDay() async throws {
        #expect(XMLOut.escape("Tom & Jerry's <\"shop\">") == "Tom &amp; Jerry&apos;s &lt;&quot;shop&quot;&gt;")
        let store = RecorderStore(modelContainer: try Store.container(inMemory: true))
        _ = try await makeDay(into: store)
        let url = try await GPXDayExporter.export(day: "2026-10-12", tz: "Europe/Warsaw", store: store)
        #expect(url.lastPathComponent == "wdig-2026-10-12.gpx")
        #expect(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(FileManager.default.fileExists(atPath: url.path))
        GPXDayExporter.cleanUp()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test(
        "A day without segments exports a track with no segment, and a segment crossing midnight goes whole into both days"
    )
    func midnightSegmentGoesIntoBothDays() async throws {
        let store = RecorderStore(modelContainer: try Store.container(inMemory: true))
        let late = Date(timeIntervalSince1970: 1_791_838_800)  // 2026-10-12 21:00 UTC, 23:00 Warsaw
        var points: [PointSample] = []
        for index in 0..<20 {
            var sample = PointSample(
                deviceId: device, recordedAt: late.addingTimeInterval(TimeInterval(index) * 600), tz: "Europe/Warsaw",
                latitude: 52.2 + Double(index) * 0.001, longitude: 21.0, hAccM: 8)
            sample.activity = 4
            points.append(sample)
        }
        try await store.append(points)
        try await store.upsert(
            SegmentSnapshot(
                kind: "trip", startAt: late, endAt: late.addingTimeInterval(19 * 600), tz: "Europe/Warsaw",
                modeDetected: "cycling",
                modeConf: "high", modeType: "bike", distanceM: 2_000, pointCount: 20))
        let first = try await GPXDayExporter.document(day: "2026-10-12", tz: "Europe/Warsaw", store: store, now: late)
        let second = try await GPXDayExporter.document(day: "2026-10-13", tz: "Europe/Warsaw", store: store, now: late)
        #expect(first.components(separatedBy: "<trkpt ").count == 21)
        #expect(second.components(separatedBy: "<trkpt ").count == 21)
        let empty = try await GPXDayExporter.document(day: "2026-10-20", tz: "Europe/Warsaw", store: store, now: late)
        #expect(empty.contains("<trk>\n  <name>2026-10-20</name>\n</trk>"))
    }
}
