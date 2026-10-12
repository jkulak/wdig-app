import Foundation
import UIKit

/// The battery and the power mode as a value.
struct PowerSnapshot: Sendable, Equatable {
    /// 0...1, or nil when unknown.
    var level: Float?
    /// `UIDevice.BatteryState` raw value: 0 unknown, 1 unplugged, 2 charging, 3 full.
    var state: Int
    var lowPowerMode: Bool

    static let unknown = PowerSnapshot(level: nil, state: 0, lowPowerMode: false)

    var levelPercent: Int16? {
        guard let level, level >= 0 else { return nil }
        return Int16((level * 100).rounded())
    }

    var stateCode: Int16? {
        state == 0 ? nil : Int16(state)
    }

    var isCharging: Bool {
        state == 2 || state == 3
    }
}

/// When the recorder drops to coarse mode: Low Power Mode is the user's own signal that
/// battery matters more than detail, and under 20 % the phone says the same.
enum PowerPolicy {
    static let lowLevel: Float = 0.20

    static func wantsCoarse(_ power: PowerSnapshot) -> Bool {
        if power.lowPowerMode { return true }
        if power.isCharging { return false }
        if let level = power.level, level >= 0, level < lowLevel { return true }
        return false
    }

    static func reason(_ power: PowerSnapshot) -> String {
        power.lowPowerMode ? "lowPowerMode" : "batteryLow"
    }
}

/// Reads the battery and the power mode on the main actor and hands every change to the
/// recorder. It lives as long as the process, so its observers are never removed.
@MainActor
final class PowerObserver {
    private var observers: [NSObjectProtocol] = []
    private let onChange: @Sendable (PowerSnapshot) -> Void

    init(onChange: @escaping @Sendable (PowerSnapshot) -> Void) {
        self.onChange = onChange
        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        for name in [
            UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification,
            Notification.Name.NSProcessInfoPowerStateDidChange,
        ] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [onChange] _ in
                    MainActor.assumeIsolated {
                        onChange(PowerObserver.current())
                    }
                })
        }
    }

    static func current() -> PowerSnapshot {
        let device = UIDevice.current
        return PowerSnapshot(
            level: device.batteryLevel >= 0 ? device.batteryLevel : nil, state: device.batteryState.rawValue,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}
