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

    /// Writes a segment as computed; a row with the same id is replaced.
    func upsert(_ snapshot: SegmentSnapshot) throws {
        modelContext.insert(Segment(snapshot))
        try modelContext.save()
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

    private func rebuildDaySummary(for day: String) throws {
        let count = try modelContext.fetchCount(
            FetchDescriptor<Point>(predicate: #Predicate<Point> { $0.localDay == day }))
        let coarseCount = try modelContext.fetchCount(
            FetchDescriptor<Point>(predicate: #Predicate<Point> { $0.localDay == day && $0.coarse == true }))
        let existing = try modelContext.fetch(
            FetchDescriptor<DaySummary>(predicate: #Predicate<DaySummary> { $0.localDay == day }))
        if let summary = existing.first {
            summary.pointCount = Int32(count)
            summary.coarse = coarseCount > 0
            summary.updatedAt = Date()
        } else {
            modelContext.insert(
                DaySummary(
                    localDay: day, pointCount: Int32(count), tripCount: 0, stopCount: 0, distanceM: 0,
                    coarse: coarseCount > 0, updatedAt: Date()))
        }
    }
}
