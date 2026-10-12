import CoreLocation
import Foundation

/// One location as a value: what Core Location delivered, before thinning and before it
/// becomes a point of the store.
struct Fix: Sendable, Equatable {
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double
    var altitude: Double
    var verticalAccuracy: Double
    var speed: Double
    var course: Double
    var timestamp: Date

    init(_ location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        horizontalAccuracy = location.horizontalAccuracy
        altitude = location.altitude
        verticalAccuracy = location.verticalAccuracy
        speed = location.speed
        course = location.course
        timestamp = location.timestamp
    }

    init(
        latitude: Double, longitude: Double, horizontalAccuracy: Double = 10, altitude: Double = 100,
        verticalAccuracy: Double = 5, speed: Double = -1, course: Double = -1, timestamp: Date
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.altitude = altitude
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.course = course
        self.timestamp = timestamp
    }

    var coordinate: Coordinate {
        Coordinate(latitude: latitude, longitude: longitude)
    }

    /// The fix as a point of the store.
    func sample(deviceId: UUID, source: String, coarse: Bool, power: PowerSnapshot, tz: String) -> PointSample {
        var sample = PointSample(
            deviceId: deviceId, recordedAt: timestamp, tz: tz, latitude: latitude, longitude: longitude,
            hAccM: Int16(clamping: Int(horizontalAccuracy.rounded())))
        sample.altM = verticalAccuracy >= 0 ? Int16(clamping: Int(altitude.rounded())) : nil
        sample.vAccM = verticalAccuracy >= 0 ? Int16(clamping: Int(verticalAccuracy.rounded())) : nil
        sample.speedCms = speed >= 0 ? Int16(clamping: Int((speed * 100).rounded())) : -1
        sample.courseDeg = course >= 0 ? Int16(clamping: Int(course.rounded()) % 360) : -1
        sample.source = source
        sample.coarse = coarse
        sample.batteryPct = power.levelPercent
        sample.batteryState = power.stateCode
        return sample
    }
}

/// A position without the rest of a fix.
struct Coordinate: Sendable, Equatable {
    var latitude: Double
    var longitude: Double

    /// Great-circle distance in metres on a sphere of 6,371,008.8 m.
    func distance(to other: Coordinate) -> Double {
        let radius = 6_371_008.8
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * asin(min(1, sqrt(a)))
    }

    /// The component-wise median of a set of positions: immune to the drift of a few fixes.
    static func median(of coordinates: [Coordinate]) -> Coordinate? {
        guard !coordinates.isEmpty else { return nil }
        return Coordinate(
            latitude: medianValue(coordinates.map(\.latitude)), longitude: medianValue(coordinates.map(\.longitude)))
    }

    private static func medianValue(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
