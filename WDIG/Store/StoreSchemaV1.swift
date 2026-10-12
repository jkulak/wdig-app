import Foundation
import SwiftData

/// The first shape of the store. Every later change is a new `StoreSchemaV(n)` plus a
/// stage in `StoreMigrationPlan`; this one is never edited once a phone has data in it.
/// The models mirror the server's tables field for field, in camelCase, so the sync is a
/// copy and nothing is translated in between. Latitude and longitude are integers scaled
/// by 1e7, as on the server.
enum StoreSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Point.self, Segment.self, Correction.self, Place.self, Marker.self, Device.self,
            OutboxEntry.self, DaySummary.self,
        ]
    }

    /// One kept fix of the recorder. The unique key is the server's primary key.
    @Model
    final class Point {
        #Unique<Point>([\.deviceId, \.recordedAt])
        #Index<Point>([\.recordedAt], [\.localDay, \.recordedAt], [\.uploadBatchId])

        var deviceId: UUID
        var recordedAt: Date
        var tz: String
        var lat: Int32
        var lon: Int32
        var hAccM: Int16
        var altM: Int16?
        var vAccM: Int16?
        var speedCms: Int16
        var courseDeg: Int16
        var activity: Int16
        var activityConf: Int16
        var source: String
        var batteryPct: Int16?
        var batteryState: Int16?
        var coarse: Bool
        var importBatchId: UUID?
        /// The local calendar day in `tz`, `YYYY-MM-DD`, computed once on insert so a
        /// day query is an indexed string match and never a time-zone computation.
        var localDay: String
        var uploadBatchId: UUID?
        var uploadedAt: Date?

        init(_ sample: PointSample) {
            deviceId = sample.deviceId
            recordedAt = sample.recordedAt
            tz = sample.tz
            lat = sample.lat
            lon = sample.lon
            hAccM = sample.hAccM
            altM = sample.altM
            vAccM = sample.vAccM
            speedCms = sample.speedCms
            courseDeg = sample.courseDeg
            activity = sample.activity
            activityConf = sample.activityConf
            source = sample.source
            batteryPct = sample.batteryPct
            batteryState = sample.batteryState
            coarse = sample.coarse
            importBatchId = sample.importBatchId
            localDay = LocalDay.key(for: sample.recordedAt, tz: sample.tz)
            uploadBatchId = sample.uploadBatchId
            uploadedAt = nil
        }
    }

    /// A stop or a trip, as the segmenter computed it.
    @Model
    final class Segment {
        #Index<Segment>([\.startAt], [\.endAt], [\.deletedAt])

        @Attribute(.unique) var id: UUID
        var deviceId: UUID?
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
        var placeId: UUID?
        var source: String
        var computedBy: String
        var algorithmVersion: Int16
        var steps: Int32?
        var coarse: Bool
        var updatedAt: Date
        var deletedAt: Date?

        init(_ snapshot: SegmentSnapshot) {
            id = snapshot.id
            deviceId = snapshot.deviceId
            kind = snapshot.kind
            startAt = snapshot.startAt
            endAt = snapshot.endAt
            tz = snapshot.tz
            modeDetected = snapshot.modeDetected
            modeConf = snapshot.modeConf
            modeType = snapshot.modeType
            distanceM = snapshot.distanceM
            pointCount = snapshot.pointCount
            centerLat = snapshot.centerLat
            centerLon = snapshot.centerLon
            placeId = snapshot.placeId
            source = snapshot.source
            computedBy = snapshot.computedBy
            algorithmVersion = snapshot.algorithmVersion
            steps = snapshot.steps
            coarse = snapshot.coarse
            updatedAt = snapshot.updatedAt
            deletedAt = snapshot.deletedAt
        }
    }

    /// An edit of the timeline, as a time-ranged override that survives re-segmentation.
    @Model
    final class Correction {
        #Index<Correction>([\.updatedAt])

        @Attribute(.unique) var id: UUID
        var kind: String
        var startAt: Date
        var endAt: Date
        var payload: Data
        var createdAt: Date
        var updatedAt: Date
        var deletedAt: Date?

        init(id: UUID, kind: String, startAt: Date, endAt: Date, payload: Data, createdAt: Date) {
            self.id = id
            self.kind = kind
            self.startAt = startAt
            self.endAt = endAt
            self.payload = payload
            self.createdAt = createdAt
            updatedAt = createdAt
            deletedAt = nil
        }
    }

    /// A named place with a radius; stops within it get its name.
    @Model
    final class Place {
        #Index<Place>([\.updatedAt])

        @Attribute(.unique) var id: UUID
        var name: String
        var lat: Int32
        var lon: Int32
        var radiusM: Int16
        var createdAt: Date
        var updatedAt: Date
        var deletedAt: Date?

        init(id: UUID, name: String, lat: Int32, lon: Int32, radiusM: Int16 = 100, createdAt: Date) {
            self.id = id
            self.name = name
            self.lat = lat
            self.lon = lon
            self.radiusM = radiusM
            self.createdAt = createdAt
            updatedAt = createdAt
            deletedAt = nil
        }
    }

    /// A spot marked by hand, with a note and an optional photo.
    @Model
    final class Marker {
        #Index<Marker>([\.updatedAt])

        @Attribute(.unique) var id: UUID
        var recordedAt: Date
        var tz: String
        var lat: Int32
        var lon: Int32
        var note: String
        var photoRef: String?
        var createdAt: Date
        var updatedAt: Date
        var deletedAt: Date?

        init(id: UUID, recordedAt: Date, tz: String, lat: Int32, lon: Int32, note: String, createdAt: Date) {
            self.id = id
            self.recordedAt = recordedAt
            self.tz = tz
            self.lat = lat
            self.lon = lon
            self.note = note
            photoRef = nil
            self.createdAt = createdAt
            updatedAt = createdAt
            deletedAt = nil
        }
    }

    /// This phone, as the server knows it. Exactly one row, created on first launch.
    @Model
    final class Device {
        @Attribute(.unique) var id: UUID
        var name: String
        var platform: String
        var appVersion: String
        var createdAt: Date
        var lastSeenAt: Date

        init(id: UUID, name: String, appVersion: String, createdAt: Date) {
            self.id = id
            self.name = name
            platform = "ios"
            self.appVersion = appVersion
            self.createdAt = createdAt
            lastSeenAt = createdAt
        }
    }

    /// The queue the sync drains; phone-only, never uploaded itself.
    @Model
    final class OutboxEntry {
        #Index<OutboxEntry>([\.sentAt])

        @Attribute(.unique) var id: UUID
        var kind: String
        var entityId: UUID?
        var batchId: UUID?
        var createdAt: Date
        var attempts: Int16
        var lastAttemptAt: Date?
        var lastError: String?
        var sentAt: Date?
        var state: String
        var response: String?

        init(id: UUID, kind: String, entityId: UUID?, batchId: UUID?, createdAt: Date) {
            self.id = id
            self.kind = kind
            self.entityId = entityId
            self.batchId = batchId
            self.createdAt = createdAt
            attempts = 0
            lastAttemptAt = nil
            lastError = nil
            sentAt = nil
            state = "pending"
            response = nil
        }
    }

    /// A rebuildable cache of the list of days, the same fields `GET /days` returns.
    @Model
    final class DaySummary {
        #Unique<DaySummary>([\.localDay])

        var localDay: String
        var pointCount: Int32
        var tripCount: Int32
        var stopCount: Int32
        var distanceM: Int32
        var coarse: Bool
        var updatedAt: Date

        init(
            localDay: String, pointCount: Int32, tripCount: Int32, stopCount: Int32, distanceM: Int32, coarse: Bool,
            updatedAt: Date
        ) {
            self.localDay = localDay
            self.pointCount = pointCount
            self.tripCount = tripCount
            self.stopCount = stopCount
            self.distanceM = distanceM
            self.coarse = coarse
            self.updatedAt = updatedAt
        }
    }
}

typealias Point = StoreSchemaV1.Point
typealias Segment = StoreSchemaV1.Segment
typealias Correction = StoreSchemaV1.Correction
typealias Place = StoreSchemaV1.Place
typealias Marker = StoreSchemaV1.Marker
typealias Device = StoreSchemaV1.Device
typealias OutboxEntry = StoreSchemaV1.OutboxEntry
typealias DaySummary = StoreSchemaV1.DaySummary
