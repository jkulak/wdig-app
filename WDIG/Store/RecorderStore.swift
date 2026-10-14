import Foundation
import SwiftData

/// The only writer of the store, and the reader the recorder, the segmenter and the
/// views go through. Everything crosses its boundary as value snapshots, never as model
/// objects, so no caller holds a `ModelContext` of its own.
@ModelActor
actor RecorderStore {
    /// Every write that touches points or segments is announced here, with the days it
    /// touched, once it is saved.
    nonisolated let changes = StoreChangeSignal()

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
        changes.publish(StoreChange(days: days))
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
        var days = Set<String>()
        for point in try modelContext.fetch(descriptor) {
            let sample = timeline.sample(at: point.recordedAt)
            guard sample.code != ActivityCode.unknown || sample.confidence > 0 else { continue }
            point.activity = sample.code
            point.activityConf = sample.confidence
            changed += 1
            days.insert(point.localDay)
        }
        if changed > 0 {
            try modelContext.save()
            changes.publish(StoreChange(days: days))
        }
        return changed
    }

    /// Writes a segment as computed; a row with the same id is replaced.
    func upsert(_ snapshot: SegmentSnapshot) throws {
        modelContext.insert(Segment(snapshot))
        try modelContext.save()
        changes.publish(
            StoreChange(days: Set(Self.localDays(from: snapshot.startAt, to: snapshot.endAt, tz: snapshot.tz))))
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

    /// The start of the latest phone stop beginning at or before `moment`: where a run picks
    /// up, as a trip begins at its stop's last fix and only a stop's own fixes make it again.
    func latestPhoneStopStart(ofDevice deviceId: UUID, atOrBefore moment: Date) throws -> Date? {
        // The literals as values: five conditions with two of them spelt inline are more than the
        // predicate macro's type-checker takes in reasonable time.
        let phone = "phone"
        let stop = "stop"
        var descriptor = FetchDescriptor<Segment>(
            predicate: #Predicate<Segment> {
                $0.deviceId == deviceId && $0.computedBy == phone && $0.deletedAt == nil && $0.kind == stop
                    && $0.startAt <= moment
            })
        descriptor.sortBy = [SortDescriptor(\.startAt, order: .reverse)]
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.startAt
    }

    func phoneSegments(ofDevice deviceId: UUID, startingAt from: Date) throws -> [SegmentSnapshot] {
        var descriptor = FetchDescriptor<Segment>(
            predicate: #Predicate<Segment> {
                $0.deviceId == deviceId && $0.computedBy == "phone" && $0.deletedAt == nil && $0.startAt >= from
            })
        descriptor.sortBy = [SortDescriptor(\.startAt)]
        return try modelContext.fetch(descriptor).map(SegmentSnapshot.init)
    }

    /// The start of the earliest phone segment still running at `moment`, so a run over a day
    /// can begin where the segment crossing its midnight did instead of cutting it there.
    func earliestPhoneSegmentStart(ofDevice deviceId: UUID, overlapping moment: Date) throws -> Date? {
        var descriptor = FetchDescriptor<Segment>(
            predicate: #Predicate<Segment> {
                $0.deviceId == deviceId && $0.computedBy == "phone" && $0.deletedAt == nil && $0.startAt < moment
                    && $0.endAt > moment
            })
        descriptor.sortBy = [SortDescriptor(\.startAt)]
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.startAt
    }

    /// The segmenter's result for everything from `from` on: rows it no longer produces are
    /// soft-deleted, the rest written by their stable ids, and the touched days rebuilt. A row
    /// the segmenter computed the same again is left as it is, `updatedAt` included, so a run
    /// over unchanged points writes nothing and announces nothing.
    func replacePhoneSegments(ofDevice deviceId: UUID, startingAt from: Date, with snapshots: [SegmentSnapshot]) throws
    {
        let keep = Set(snapshots.map(\.id))
        var days = Set<String>()
        let existing = try modelContext.fetch(
            FetchDescriptor<Segment>(
                predicate: #Predicate<Segment> {
                    $0.deviceId == deviceId && $0.computedBy == "phone" && $0.deletedAt == nil && $0.startAt >= from
                }))
        let stored = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for segment in existing where !keep.contains(segment.id) {
            segment.deletedAt = Date()
            segment.updatedAt = Date()
            days.formUnion(Self.localDays(from: segment.startAt, to: segment.endAt, tz: segment.tz))
        }
        for snapshot in snapshots {
            if let row = stored[snapshot.id], Self.sameSegment(row, as: snapshot) { continue }
            modelContext.insert(Segment(snapshot))
            days.formUnion(Self.localDays(from: snapshot.startAt, to: snapshot.endAt, tz: snapshot.tz))
        }
        guard !days.isEmpty else { return }
        try modelContext.save()
        for day in days {
            try rebuildDaySummary(for: day)
        }
        try modelContext.save()
        changes.publish(StoreChange(days: days))
    }

    /// Whether a stored row already says what the segmenter computed, on the fields a run can
    /// change; `updatedAt`, `placeId` and the deletion mark are the store's own.
    private static func sameSegment(_ row: Segment, as snapshot: SegmentSnapshot) -> Bool {
        row.kind == snapshot.kind && row.startAt == snapshot.startAt && row.endAt == snapshot.endAt
            && row.tz == snapshot.tz && row.modeDetected == snapshot.modeDetected && row.modeConf == snapshot.modeConf
            && row.modeType == snapshot.modeType && row.distanceM == snapshot.distanceM
            && row.pointCount == snapshot.pointCount && row.centerLat == snapshot.centerLat
            && row.centerLon == snapshot.centerLon && row.steps == snapshot.steps && row.coarse == snapshot.coarse
            && row.source == snapshot.source && row.algorithmVersion == snapshot.algorithmVersion
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
        var touched = days
        for point in points {
            modelContext.delete(point)
        }
        let segments = try modelContext.fetch(
            FetchDescriptor<Segment>(predicate: #Predicate<Segment> { $0.deviceId == deviceId }))
        for segment in segments {
            touched.formUnion(Self.localDays(from: segment.startAt, to: segment.endAt, tz: segment.tz))
            modelContext.delete(segment)
        }
        try modelContext.save()
        for day in days {
            try rebuildDaySummary(for: day)
        }
        try modelContext.save()
        changes.publish(StoreChange(days: touched))
        return (points.count, segments.count)
    }

    /// The rows of the list of days, newest first: the points of each day from its summary,
    /// and its trips, stops and distance counted from the live phone segments in one fetch, so
    /// a segment written on its own, as the demo month's are, counts without a rebuild.
    func daysWithData() throws -> [DaySummarySnapshot] {
        var descriptor = FetchDescriptor<DaySummary>(predicate: #Predicate<DaySummary> { $0.pointCount > 0 })
        descriptor.sortBy = [SortDescriptor(\.localDay, order: .reverse)]
        var rows = try modelContext.fetch(descriptor).map(DaySummarySnapshot.init)
        guard !rows.isEmpty else { return rows }
        var segments = FetchDescriptor<Segment>(
            predicate: #Predicate<Segment> { $0.computedBy == "phone" && $0.deletedAt == nil })
        segments.propertiesToFetch = [\.kind, \.startAt, \.endAt, \.tz, \.distanceM]
        var totals: [String: DayTotals] = [:]
        for segment in try modelContext.fetch(segments) {
            for day in Self.localDays(from: segment.startAt, to: segment.endAt, tz: segment.tz) {
                guard let bounds = LocalDay.bounds(of: day, tz: segment.tz), segment.startAt < bounds.end,
                    segment.endAt > bounds.start
                else { continue }
                totals[day, default: DayTotals()].add(
                    kind: segment.kind,
                    distanceM: Self.distance(
                        segment.distanceM, from: segment.startAt, to: segment.endAt, within: bounds))
            }
        }
        for index in rows.indices {
            let total = totals[rows[index].localDay] ?? DayTotals()
            rows[index].tripCount = total.trips
            rows[index].stopCount = total.stops
            rows[index].distanceM = Int32(total.distanceM.rounded())
        }
        return rows
    }

    /// A day's share of its segments: a count for each, and a trip's distance on that day.
    private struct DayTotals {
        var trips: Int32 = 0
        var stops: Int32 = 0
        var distanceM = 0.0

        mutating func add(kind: String, distanceM: Double) {
            if kind == "trip" {
                trips += 1
                self.distanceM += distanceM
            } else {
                stops += 1
            }
        }
    }

    /// A trip's distance on one local day: all of it when the trip stays inside the day, else
    /// the share in proportion to the time spent on that side of midnight.
    static func distance(
        _ distanceM: Int32, from startAt: Date, to endAt: Date, within bounds: (start: Date, end: Date)
    ) -> Double {
        let total = endAt.timeIntervalSince(startAt)
        guard total > 0 else { return Double(distanceM) }
        let inside = min(endAt, bounds.end).timeIntervalSince(max(startAt, bounds.start))
        return Double(distanceM) * max(0, inside) / total
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

    // MARK: - Diagnostics

    func logDiagnostic(_ record: DiagnosticRecord) throws {
        modelContext.insert(DiagnosticEvent(record))
        try modelContext.save()
    }

    func diagnostics(onDay day: String) throws -> [DiagnosticRecord] {
        var descriptor = FetchDescriptor<DiagnosticEvent>(predicate: #Predicate<DiagnosticEvent> { $0.localDay == day })
        descriptor.sortBy = [SortDescriptor(\.at)]
        return try modelContext.fetch(descriptor).map(DiagnosticRecord.init)
    }

    func diagnostics(from start: Date, to end: Date) throws -> [DiagnosticRecord] {
        var descriptor = FetchDescriptor<DiagnosticEvent>(
            predicate: #Predicate<DiagnosticEvent> { $0.at >= start && $0.at < end })
        descriptor.sortBy = [SortDescriptor(\.at)]
        return try modelContext.fetch(descriptor).map(DiagnosticRecord.init)
    }

    func pruneDiagnostics(olderThan cutoff: Date) throws -> Int {
        let old = try modelContext.fetch(
            FetchDescriptor<DiagnosticEvent>(predicate: #Predicate<DiagnosticEvent> { $0.at < cutoff }))
        for event in old {
            modelContext.delete(event)
        }
        try modelContext.save()
        return old.count
    }

    /// When the kept fixes of a stretch were recorded, for the gap detector.
    func pointTimes(from start: Date, to end: Date) throws -> [Date] {
        var descriptor = FetchDescriptor<Point>(
            predicate: #Predicate<Point> { $0.recordedAt >= start && $0.recordedAt < end })
        descriptor.sortBy = [SortDescriptor(\.recordedAt)]
        descriptor.propertiesToFetch = [\.recordedAt]
        return try modelContext.fetch(descriptor).map(\.recordedAt)
    }

    /// The day's row of the list: its points, and its phone segments counted on every day they
    /// touch, with a trip's distance split in proportion to the time on each side of midnight.
    private func rebuildDaySummary(for day: String) throws {
        let count = try modelContext.fetchCount(
            FetchDescriptor<Point>(predicate: #Predicate<Point> { $0.localDay == day }))
        let coarseCount = try modelContext.fetchCount(
            FetchDescriptor<Point>(predicate: #Predicate<Point> { $0.localDay == day && $0.coarse == true }))
        var totals = DayTotals()
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
                totals.add(
                    kind: segment.kind,
                    distanceM: Self.distance(
                        segment.distanceM, from: segment.startAt, to: segment.endAt, within: bounds))
                coarseSegments = coarseSegments || segment.coarse
            }
        }
        let existing = try modelContext.fetch(
            FetchDescriptor<DaySummary>(predicate: #Predicate<DaySummary> { $0.localDay == day }))
        if let summary = existing.first {
            summary.pointCount = Int32(count)
            summary.tripCount = totals.trips
            summary.stopCount = totals.stops
            summary.distanceM = Int32(totals.distanceM.rounded())
            summary.coarse = coarseCount > 0 || coarseSegments
            summary.updatedAt = Date()
        } else {
            modelContext.insert(
                DaySummary(
                    localDay: day, pointCount: Int32(count), tripCount: totals.trips, stopCount: totals.stops,
                    distanceM: Int32(totals.distanceM.rounded()), coarse: coarseCount > 0 || coarseSegments,
                    updatedAt: Date()))
        }
    }
}
