import CoreMotion
import Foundation

/// A motion class with its confidence, as the recorder stamps it on every fix: the integer
/// codes the server shares (0 unknown, 1 stationary, 2 walking, 3 running, 4 cycling,
/// 5 automotive; confidence 0 low, 1 medium, 2 high).
struct ActivitySample: Sendable, Equatable {
    var code: Int16
    var confidence: Int16
    var startDate: Date
}

enum ActivityCode {
    static let unknown: Int16 = 0
    static let stationary: Int16 = 1
    static let walking: Int16 = 2
    static let running: Int16 = 3
    static let cycling: Int16 = 4
    static let automotive: Int16 = 5

    /// Several flags can be true at once (automotive and stationary at a red light); the
    /// faster way of moving wins, and `unknown` wins over everything.
    static func code(
        stationary: Bool, walking: Bool, running: Bool, cycling: Bool, automotive: Bool, unknown: Bool
    ) -> Int16 {
        if unknown { return Self.unknown }
        if automotive { return Self.automotive }
        if cycling { return Self.cycling }
        if running { return Self.running }
        if walking { return Self.walking }
        if stationary { return Self.stationary }
        return Self.unknown
    }

    static func code(for activity: CMMotionActivity) -> Int16 {
        code(
            stationary: activity.stationary, walking: activity.walking, running: activity.running,
            cycling: activity.cycling, automotive: activity.automotive, unknown: activity.unknown)
    }

    static func confidence(_ confidence: CMMotionActivityConfidence) -> Int16 {
        switch confidence {
        case .low: 0
        case .medium: 1
        case .high: 2
        @unknown default: 0
        }
    }

    /// The way of moving the recorder configures itself for; nil when the class says nothing.
    static func kind(for code: Int16) -> MovementKind? {
        switch code {
        case automotive: .vehicle
        case cycling: .cycle
        case walking, running: .foot
        default: nil
        }
    }
}

enum MotionAuthorization: String, Sendable {
    case notDetermined
    case restricted
    case denied
    case authorized
    case unavailable
}

/// What delivers motion classes: Core Motion on the phone, a fake in tests and on the simulator.
protocol ActivityProviding: Sendable {
    var authorization: MotionAuthorization { get }
    func startUpdates(_ handler: @escaping @Sendable (ActivitySample) -> Void)
    func stopUpdates()
    /// The classes Core Motion kept for the range, oldest first (it keeps seven days).
    func history(from: Date, to: Date) async throws -> [ActivitySample]
}

/// The latest class at any moment, from the samples seen so far.
struct ActivityTimeline: Sendable {
    private(set) var samples: [ActivitySample] = []

    mutating func add(_ sample: ActivitySample) {
        samples.append(sample)
        if samples.count > 500 {
            samples.removeFirst(samples.count - 500)
        }
    }

    /// The sample in force at `date`: the latest whose start is at or before it, or unknown.
    func sample(at date: Date) -> ActivitySample {
        samples.last { $0.startDate <= date }
            ?? ActivitySample(code: ActivityCode.unknown, confidence: 0, startDate: date)
    }
}

/// How far back a back-fill may ask: Core Motion keeps seven days, so a phone that was away
/// longer leaves its earlier points unknown for good.
enum BackfillPolicy {
    static let keptSeconds: TimeInterval = 7 * 86_400

    static func range(lastStamped: Date?, now: Date) -> (from: Date, to: Date) {
        let earliest = now.addingTimeInterval(-keptSeconds)
        let from = max(lastStamped ?? earliest, earliest)
        return (from, now)
    }
}

final class CoreMotionActivitySource: ActivityProviding, @unchecked Sendable {
    private let manager = CMMotionActivityManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.jkulak.wdig.motion"
        return queue
    }()

    var authorization: MotionAuthorization {
        guard CMMotionActivityManager.isActivityAvailable() else { return .unavailable }
        switch CMMotionActivityManager.authorizationStatus() {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .notDetermined
        }
    }

    func startUpdates(_ handler: @escaping @Sendable (ActivitySample) -> Void) {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        manager.startActivityUpdates(to: queue) { activity in
            guard let activity else { return }
            handler(
                ActivitySample(
                    code: ActivityCode.code(for: activity), confidence: ActivityCode.confidence(activity.confidence),
                    startDate: activity.startDate))
        }
    }

    func stopUpdates() {
        manager.stopActivityUpdates()
    }

    func history(from: Date, to: Date) async throws -> [ActivitySample] {
        guard CMMotionActivityManager.isActivityAvailable() else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            manager.queryActivityStarting(from: from, to: to, to: queue) { activities, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(
                        returning: (activities ?? []).map {
                            ActivitySample(
                                code: ActivityCode.code(for: $0), confidence: ActivityCode.confidence($0.confidence),
                                startDate: $0.startDate)
                        })
                }
            }
        }
    }
}

/// For tests and the simulator, where Core Motion has nothing to say.
final class FakeActivitySource: ActivityProviding, @unchecked Sendable {
    var authorization: MotionAuthorization = .authorized
    var live: [ActivitySample] = []
    var stored: [ActivitySample] = []
    private(set) var historyRequests: [(from: Date, to: Date)] = []

    func startUpdates(_ handler: @escaping @Sendable (ActivitySample) -> Void) {
        for sample in live {
            handler(sample)
        }
    }

    func stopUpdates() {}

    func history(from: Date, to: Date) async throws -> [ActivitySample] {
        historyRequests.append((from, to))
        return stored.filter { $0.startDate >= from && $0.startDate <= to }
    }
}
