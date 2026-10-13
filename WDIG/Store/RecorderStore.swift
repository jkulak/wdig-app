import Foundation
import SwiftData

/// The only writer of the store, and the reader the recorder, the segmenter and the
/// views go through. Everything crosses its boundary as value snapshots, never as model
/// objects, so no caller holds a `ModelContext` of its own.
@ModelActor
actor RecorderStore {
    /// Inserts kept fixes in one transaction and refreshes the day list for the days they
    /// touch. A fix with the key of one already stored replaces it rather than doubling it.
    func append(_ fixes: [PointSample]) throws {
        guard !fixes.isEmpty else { return }
        for fix in fixes {
            modelContext.insert(Point(fix))
        }
        try modelContext.save()
        let days = Set(fixes.map { LocalDay.key(for: $0.recordedAt, tz: $0.tz) })
        for day in days {
            try rebuildDaySummary(for: day)
        }
        try modelContext.save()
    }

    func points(onDay day: String) throws -> [PointSample] {
        var descriptor = FetchDescriptor<Point>(predicate: #Predicate<Point> { $0.localDay == day })
        descriptor.sortBy = [SortDescriptor(\.recordedAt)]
        return try modelContext.fetch(descriptor).map(PointSample.init)
    }

    func points(from start: Date, to end: Date) throws -> [PointSample] {
        var descriptor = FetchDescriptor<Point>(
            predicate: #Predicate<Point> { $0.recordedAt >= start && $0.recordedAt < end })
        descriptor.sortBy = [SortDescriptor(\.recordedAt)]
        return try modelContext.fetch(descriptor).map(PointSample.init)
    }

    func pointCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<Point>())
    }

    func pointCount(onDay day: String) throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<Point>(predicate: #Predicate<Point> { $0.localDay == day }))
    }

    func lastPoint() throws -> PointSample? {
        var descriptor = FetchDescriptor<Point>()
        descriptor.sortBy = [SortDescriptor(\.recordedAt, order: .reverse)]
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map(PointSample.init)
    }

    /// Segments that touch the local day, so one crossing midnight comes back on both days.
    func segments(overlappingDay day: String, tz: String) throws -> [SegmentSnapshot] {
        guard let bounds = LocalDay.bounds(of: day, tz: tz) else { return [] }
        let start = bounds.start
        let end = bounds.end
        var descriptor = FetchDescriptor<Segment>(
            predicate: #Predicate<Segment> { $0.startAt < end && $0.endAt > start && $0.deletedAt == nil })
        descriptor.sortBy = [SortDescriptor(\.startAt)]
        return try modelContext.fetch(descriptor).map(SegmentSnapshot.init)
    }

    /// The time of the newest point that carries a motion class, the back-fill's starting point.
    func latestStampedPointDate() throws -> Date? {
        var descriptor = FetchDescriptor<Point>(predicate: #Predicate<Point> { $0.activityConf > 0 })
        descriptor.sortBy = [SortDescriptor(\.recordedAt, order: .reverse)]
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.recordedAt
    }

    /// Stamps the points of the range that have no class yet and were not uploaded with the
    /// class in force at their time; returns how many changed.
    func restampActivity(from start: Date, to end: Date, samples: [ActivitySample]) throws -> Int {
        guard !samples.isEmpty else { return 0 }
        var timeline = ActivityTimeline()
        for sample in samples.sorted(by: { $0.startDate < $1.startDate }) {
            timeline.add(sample)
        }
        let descriptor = FetchDescriptor<Point>(
            predicate: #Predicate<Point> {
                $0.recordedAt >= start && $0.recordedAt <= end && $0.activityConf == 0 && $0.uploadBatchId == nil
            })
        var changed = 0
        for point in try modelContext.fetch(descriptor) {
            let sample = timeline.sample(at: point.recordedAt)
            guard sample.code != ActivityCode.unknown || sample.confidence > 0 else { continue }
            point.activity = sample.code
            point.activityConf = sample.confidence
            changed += 1
        }
        if changed > 0 {
            try modelContext.save()
        }
        return changed
    }

    /// Writes a segment as computed; a row with the same id is replaced.
    func upsert(_ snapshot: SegmentSnapshot) throws {
        modelContext.insert(Segment(snapshot))
        try modelContext.save()
    }

    /// This phone's device id, once `ensureDevice` has run.
    func deviceId() throws -> UUID? {
        try modelContext.fetch(FetchDescriptor<Device>()).first?.id
    }

    func points(ofDevice deviceId: UUID, from start: Date, to end: Date) throws -> [PointSample] {
        var descriptor = FetchDescriptor<Point>(
            predicate: #Predicate<Point> { $0.deviceId == deviceId && $0.recordedAt >= start && $0.recordedAt < end })
        descriptor.sortBy = [SortDescriptor(\.recordedAt)]
        return try modelContext.fetch(descriptor).map(PointSample.init)
    }

    /// The starts of the last `count` phone segments of a device, oldest first.
    func phoneSegmentStarts(ofDevice deviceId: UUID, last count: Int) throws -> [Date] {
        var descriptor = FetchDescriptor<Segment>(
            predicate: #Predicate<Segment> {
                $0.deviceId == deviceId && $0.computedBy == "phone" && $0.deletedAt == nil
            })
        descriptor.sortBy = [SortDescriptor(\.startAt, order: .reverse)]
        descriptor.fetchLimit = count
        return try modelContext.fetch(descriptor).map(\.startAt).reversed()
    }

    func phoneSegments(ofDevice deviceId: UUID, startingAt from: Date) throws -> [SegmentSnapshot] {
        var descriptor = FetchDescriptor<Segment>(
            predicate: #Predicate<Segment> {
                $0.deviceId == deviceId && $0.computedBy == "phone" && $0.deletedAt == nil && $0.startAt >= from
            })
        descriptor.sortBy = [SortDescriptor(\.startAt)]
        return try modelContext.fetch(descriptor).map(SegmentSnapshot.init)
    }

    /// The segmenter's result for everything from `from` on: rows it no longer produces are
    /// soft-deleted, the rest written by their stable ids, and the touched days rebuilt.
    func replacePhoneSegments(ofDevice deviceId: UUID, startingAt from: Date, with snapshots: [SegmentSnapshot]) throws
    {
        let keep = Set(snapshots.map(\.id))
        var days = Set<String>()
        let existing = try modelContext.fetch(
            FetchDescriptor<Segment>(
                predicate: #Predicate<Segment> {
                    $0.deviceId == deviceId && $0.computedBy == "phone" && $0.deletedAt == nil && $0.startAt >= from
                }))
        for segment in existing where !keep.contains(segment.id) {
            segment.deletedAt = Date()
            segment.updatedAt = Date()
            days.formUnion(Self.localDays(from: segment.startAt, to: segment.endAt, tz: segment.tz))
        }
        for snapshot in snapshots {
            modelContext.insert(Segment(snapshot))
            days.formUnion(Self.localDays(from: snapshot.startAt, to: snapshot.endAt, tz: snapshot.tz))
        }
        try modelContext.save()
        for day in days {
            try rebuildDaySummary(for: day)
        }
        try modelContext.save()
    }

    /// Every local day a range touches, in its zone.
    static func localDays(from start: Date, to end: Date, tz: String) -> [String] {
        var days: [String] = []
        var cursor = start
        while cursor <= end {
            days.append(LocalDay.key(for: cursor, tz: tz))
            cursor = cursor.addingTimeInterval(86_400)
        }
        let last = LocalDay.key(for: end, tz: tz)
        if days.last != last {
            days.append(last)
        }
        return days
    }

    /// Removes every point and segment of one device, for the demo data; the raw points of
    /// the phone's own device are never deleted through here.
    func deleteEverything(ofDevice deviceId: UUID) throws -> (points: Int, segments: Int) {
        let points = try modelContext.fetch(
            FetchDescriptor<Point>(predicate: #Predicate<Point> { $0.deviceId == deviceId }))
        let days = Set(points.map(\.localDay))
        for point in points {
            modelContext.delete(point)
        }
        let segments = try modelContext.fetch(
            FetchDescriptor<Segment>(predicate: #Predicate<Segment> { $0.deviceId == deviceId }))
        for segment in segments {
            modelContext.delete(segment)
        }
        try modelContext.save()
        for day in days {
            try rebuildDaySummary(for: day)
        }
        try modelContext.save()
        return (points.count, segments.count)
    }

    func daysWithData() throws -> [DaySummarySnapshot] {
        var descriptor = FetchDescriptor<DaySummary>(predicate: #Predicate<DaySummary> { $0.pointCount > 0 })
        descriptor.sortBy = [SortDescriptor(\.localDay, order: .reverse)]
        return try modelContext.fetch(descriptor).map(DaySummarySnapshot.init)
    }

    /// The one device row, created on the first call and kept for the life of the install.
    func ensureDevice(name: String, appVersion: String) throws -> UUID {
        if let device = try modelContext.fetch(FetchDescriptor<Device>()).first {
            device.lastSeenAt = Date()
            device.appVersion = appVersion
            try modelContext.save()
            return device.id
        }
        let device = Device(id: .v7(), name: name, appVersion: appVersion, createdAt: Date())
        modelContext.insert(device)
        try modelContext.save()
        return device.id
    }

    /// The day's row of the list: its points, and its phone segments counted on every day they
    /// touch, with a trip's distance split in proportion to the time on each side of midnight.
    private func rebuildDaySummary(for day: String) throws {
        let count = try modelContext.fetchCount(
            FetchDescriptor<Point>(predicate: #Predicate<Point> { $0.localDay == day }))
        let coarseCount = try modelContext.fetchCount(
            FetchDescriptor<Point>(predicate: #Predicate<Point> { $0.localDay == day && $0.coarse == true }))
        var trips: Int32 = 0
        var stops: Int32 = 0
        var distance = 0.0
        var coarseSegments = false
        let dayPoints = try modelContext.fetch(
            FetchDescriptor<Point>(predicate: #Predicate<Point> { $0.localDay == day }))
        let tz = dayPoints.first?.tz ?? TimeZone.current.identifier
        if let bounds = LocalDay.bounds(of: day, tz: tz) {
            let start = bounds.start
            let end = bounds.end
            let segments = try modelContext.fetch(
                FetchDescriptor<Segment>(
                    predicate: #Predicate<Segment> {
                        $0.computedBy == "phone" && $0.deletedAt == nil && $0.startAt < end && $0.endAt > start
                    }))
            for segment in segments {
                if segment.kind == "trip" {
                    trips += 1
                    let total = segment.endAt.timeIntervalSince(segment.startAt)
                    let inside = min(segment.endAt, end).timeIntervalSince(max(segment.startAt, start))
                    distance += total > 0 ? Double(segment.distanceM) * inside / total : Double(segment.distanceM)
                } else {
                    stops += 1
                }
                coarseSegments = coarseSegments || segment.coarse
            }
        }
        let existing = try modelContext.fetch(
            FetchDescriptor<DaySummary>(predicate: #Predicate<DaySummary> { $0.localDay == day }))
        if let summary = existing.first {
            summary.pointCount = Int32(count)
            summary.tripCount = trips
            summary.stopCount = stops
            summary.distanceM = Int32(distance.rounded())
            summary.coarse = coarseCount > 0 || coarseSegments
            summary.updatedAt = Date()
        } else {
            modelContext.insert(
                DaySummary(
                    localDay: day, pointCount: Int32(count), tripCount: trips, stopCount: stops,
                    distanceM: Int32(distance.rounded()), coarse: coarseCount > 0 || coarseSegments, updatedAt: Date()))
        }
    }
}
