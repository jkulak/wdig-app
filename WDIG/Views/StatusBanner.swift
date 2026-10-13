import SwiftUI

/// One line over the map: is recording alive, and if not, why. Tapping leads to where it
/// can be fixed, dismisses a gap, or opens the diagnostics.
struct StatusBanner: View {
    @State private var hub = RecorderHub.shared
    @Binding var showDiagnostics: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Button {
                switch hub.status {
                case .needsAlways, .denied: hub.openSystemSettings()
                case .gap: hub.dismissGap()
                default: showDiagnostics = true
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                    Text(text(now: context.date)).lineLimit(1)
                    Spacer()
                }
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.thinMaterial)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("status-banner")
        }
    }

    private var symbol: String {
        switch hub.status {
        case .off: "pause.circle"
        case .needsAlways, .denied: "exclamationmark.triangle"
        case .on: "record.circle"
        case .coarse: "tortoise"
        case .gap: "clock.badge.exclamationmark"
        }
    }

    private func text(now: Date) -> String {
        switch hub.status {
        case .off:
            return String(localized: "Tracking off")
        case .needsAlways:
            return String(localized: "Location: While Using, tap to allow Always")
        case .denied:
            return String(localized: "Location off for WDIG, tap to open Settings")
        case .on(let lastFixAt):
            guard let lastFixAt else { return String(localized: "Tracking on · no fix yet") }
            let minutes = max(0, Int(now.timeIntervalSince(lastFixAt) / 60))
            return String(localized: "Tracking on · last fix \(Self.clock(lastFixAt)), \(minutes) min ago")
        case .coarse(.lowPowerMode):
            return String(localized: "Coarse mode · Low Power Mode")
        case .coarse(.battery(let percent)):
            return String(localized: "Coarse mode · battery \(percent.map { "\($0) %" } ?? "low")")
        case .gap(let gap):
            return String(localized: "No fixes between \(Self.clock(gap.from)) and \(Self.clock(gap.to))")
        }
    }

    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
    }
}
