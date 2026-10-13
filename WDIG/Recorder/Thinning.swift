import Foundation

/// Which distance rule thinning applies: the live configuration decides it until the
/// motion classes arrive.
enum MovementKind: Sendable, Equatable {
    case foot
    case cycle
    case vehicle
}

/// Decides which fixes are worth a row. A fix is kept when it is far enough from the last
/// kept one for the way of moving, or when enough time has passed; a fix without a
/// usable accuracy is dropped. Poor accuracy is kept: the segmenter ignores it, the
/// record stays honest.
enum Thinning {
    static func shouldKeep(_ fix: Fix, after last: Fix?, kind: MovementKind, settings: RecorderSettings) -> Bool {
        guard fix.horizontalAccuracy >= 0 else { return false }
        guard let last else { return true }
        if fix.timestamp.timeIntervalSince(last.timestamp) >= settings.thinSeconds { return true }
        let distance = fix.coordinate.distance(to: last.coordinate)
        return distance >= minimumDistance(for: kind, settings: settings)
    }

    static func minimumDistance(for kind: MovementKind, settings: RecorderSettings) -> Double {
        switch kind {
        case .foot: settings.thinFootM
        case .cycle: settings.thinCycleM
        case .vehicle: settings.thinVehicleM
        }
    }
}

/// The live configuration to run, from the speeds seen lately: a vehicle gets the
/// navigation configuration, everything else the fitness one. A switch needs the speed to
/// hold for the whole window, so a sprint or a red light does not flip it.
enum LiveKindPolicy {
    static let vehicleSpeed: Double = 8
    static let footSpeed: Double = 3

    static func kind(
        current: MovementKind, speeds: [(at: Date, speed: Double)], now: Date, holdSeconds: Double
    ) -> MovementKind {
        let window = speeds.filter { now.timeIntervalSince($0.at) <= holdSeconds && $0.speed >= 0 }
        guard let oldest = window.map(\.at).min(), now.timeIntervalSince(oldest) >= holdSeconds * 0.8 else {
            return current
        }
        if current != .vehicle, window.allSatisfy({ $0.speed >= vehicleSpeed }) { return .vehicle }
        if current == .vehicle, window.allSatisfy({ $0.speed <= footSpeed }) { return .foot }
        return current
    }
}

/// The live configuration from the motion class, which wins over the speed heuristic when it
/// is known: a switch needs the class to have held for the hold time, so a red light's
/// `stationary` or a sprint's `running` does not flip it.
enum ClassKindPolicy {
    static func kind(current: MovementKind, desired: MovementKind?, desiredSince: Date?, now: Date, holdSeconds: Double)
        -> MovementKind
    {
        guard let desired, desired != current, let desiredSince else { return current }
        return now.timeIntervalSince(desiredSince) >= holdSeconds ? desired : current
    }
}

/// The reference position of a stop and the test for leaving it.
enum WarmPhase {
    /// The median of the fixes kept in the reference window before the stop, or the stop fix itself.
    static func reference(recent: [Fix], stationary: Fix?, now: Date, windowSeconds: Double) -> Coordinate? {
        let window = recent.filter { now.timeIntervalSince($0.timestamp) <= windowSeconds }
        if let median = Coordinate.median(of: window.map(\.coordinate)) { return median }
        return stationary?.coordinate ?? recent.last?.coordinate
    }

    static func movedOn(_ fix: Fix, from reference: Coordinate, radius: Double) -> Bool {
        fix.horizontalAccuracy >= 0 && fix.coordinate.distance(to: reference) > radius
    }
}
