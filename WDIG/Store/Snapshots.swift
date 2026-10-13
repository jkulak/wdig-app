import Foundation

/// A kept fix as a value, safe to pass between actors. Coordinates are both the stored
/// 1e7 integers and degrees, so distances never round-trip through the scaling twice.
struct PointSample: Sendable, Equatable {
    var deviceId: UUID
    var recordedAt: Date
    var tz: String
    var lat: Int32
    var lon: Int32
    var hAccM: Int16
    var altM: Int16?
    var vAccM: Int16?
    var speedCms: Int16 = -1
    var courseDeg: Int16 = -1
    var activity: Int16 = 0
    var activityConf: Int16 = 0
    var source: String = "phone"
    var batteryPct: Int16?
    var batteryState: Int16?
    var coarse: Bool = false
    var importBatchId: UUID?
    var uploadBatchId: UUID?

    static let scale: Double = 10_000_000

    var latitude: Double { Double(lat) / Self.scale }
    var longitude: Double { Double(lon) / Self.scale }

    static func scaled(_ degrees: Double) -> Int32 {
        Int32((degrees * scale).rounded())
    }

    init(_ point: Point) {
        deviceId = point.deviceId
        recordedAt = point.recordedAt
        tz = point.tz
        lat = point.lat
        lon = point.lon
        hAccM = point.hAccM
        altM = point.altM
        vAccM = point.vAccM
        speedCms = point.speedCms
        courseDeg = point.courseDeg
        activity = point.activity
        activityConf = point.activityConf
        source = point.source
        batteryPct = point.batteryPct
        batteryState = point.batteryState
        coarse = point.coarse
        importBatchId = point.importBatchId
        uploadBatchId = point.uploadBatchId
    }

    init(deviceId: UUID, recordedAt: Date, tz: String, latitude: Double, longitude: Double, hAccM: Int16) {
        self.deviceId = deviceId
        self.recordedAt = recordedAt
        self.tz = tz
        lat = Self.scaled(latitude)
        lon = Self.scaled(longitude)
        self.hAccM = hAccM
    }
}

/// A stop or a trip as a value.
struct SegmentSnapshot: Sendable, Equatable {
    var id: UUID
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

    /// A stop's position in degrees; nil for a trip.
    var center: Coordinate? {
        guard let centerLat, let centerLon else { return nil }
        return Coordinate(
            latitude: Double(centerLat) / PointSample.scale, longitude: Double(centerLon) / PointSample.scale)
    }

    init(_ segment: Segment) {
        id = segment.id
        deviceId = segment.deviceId
        kind = segment.kind
        startAt = segment.startAt
        endAt = segment.endAt
        tz = segment.tz
        modeDetected = segment.modeDetected
        modeConf = segment.modeConf
        modeType = segment.modeType
        distanceM = segment.distanceM
        pointCount = segment.pointCount
        centerLat = segment.centerLat
        centerLon = segment.centerLon
        placeId = segment.placeId
        source = segment.source
        computedBy = segment.computedBy
        algorithmVersion = segment.algorithmVersion
        steps = segment.steps
        coarse = segment.coarse
        updatedAt = segment.updatedAt
        deletedAt = segment.deletedAt
    }

    /// A trip or a stop with the fields every segment has; the rest default to a plain trip.
    init(
        id: UUID = .v7(), kind: String, startAt: Date, endAt: Date, tz: String, modeDetected: String = "unknown",
        modeConf: String = "low", modeType: String = "other", distanceM: Int32 = 0, pointCount: Int32 = 0,
        centerLat: Int32? = nil, centerLon: Int32? = nil, algorithmVersion: Int16 = 1, coarse: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        deviceId = nil
        self.kind = kind
        self.startAt = startAt
        self.endAt = endAt
        self.tz = tz
        self.modeDetected = modeDetected
        self.modeConf = modeConf
        self.modeType = modeType
        self.distanceM = distanceM
        self.pointCount = pointCount
        self.centerLat = centerLat
        self.centerLon = centerLon
        placeId = nil
        source = "phone"
        computedBy = "phone"
        self.algorithmVersion = algorithmVersion
        steps = nil
        self.coarse = coarse
        self.updatedAt = updatedAt
        deletedAt = nil
    }
}

/// One row of the list of days.
struct DaySummarySnapshot: Sendable, Equatable {
    var localDay: String
    var pointCount: Int32
    var tripCount: Int32
    var stopCount: Int32
    var distanceM: Int32
    var coarse: Bool

    init(_ summary: DaySummary) {
        localDay = summary.localDay
        pointCount = summary.pointCount
        tripCount = summary.tripCount
        stopCount = summary.stopCount
        distanceM = summary.distanceM
        coarse = summary.coarse
    }
}
