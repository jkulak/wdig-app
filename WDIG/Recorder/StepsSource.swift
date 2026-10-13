import CoreMotion
import Foundation

/// Steps over a range, from the pedometer's seven-day history: asked once per closed trip,
/// never live.
protocol StepsProviding: Sendable {
    func steps(from: Date, to: Date) async throws -> Int?
}

enum StepsPolicy {
    static let keptSeconds: TimeInterval = 7 * 86_400

    /// Whether a trip is young enough for the pedometer to still know it.
    static func canQuery(startAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(startAt) <= keptSeconds
    }

    /// Steps per minute, the walk-or-run split's input; nil without steps or a duration.
    static func cadence(steps: Int?, startAt: Date, endAt: Date) -> Double? {
        guard let steps, endAt > startAt else { return nil }
        return Double(steps) / (endAt.timeIntervalSince(startAt) / 60)
    }
}

final class PedometerStepsSource: StepsProviding, @unchecked Sendable {
    private let pedometer = CMPedometer()

    func steps(from: Date, to: Date) async throws -> Int? {
        guard CMPedometer.isStepCountingAvailable() else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            pedometer.queryPedometerData(from: from, to: to) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data?.numberOfSteps.intValue)
                }
            }
        }
    }
}

final class FakeStepsSource: StepsProviding, @unchecked Sendable {
    var stepsPerMinute: Double = 100
    private(set) var queries: [(from: Date, to: Date)] = []

    func steps(from: Date, to: Date) async throws -> Int? {
        queries.append((from, to))
        return Int(stepsPerMinute * to.timeIntervalSince(from) / 60)
    }
}
