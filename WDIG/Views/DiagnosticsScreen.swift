import SwiftUI

/// The events of a day, newest first, with the day's counts and the export; in a Debug
/// build the recorder's numbers can be changed here.
struct DiagnosticsScreen: View {
    struct ExportedFile: Identifiable {
        let url: URL
        var id: String { url.path() }
    }

    @State private var hub = RecorderHub.shared
    @State private var day = LocalDay.key(for: Date(), tz: TimeZone.current.identifier)
    @State private var events: [DiagnosticRecord] = []
    @State private var pointsKept = 0
    @State private var filter = ""
    @State private var exported: ExportedFile?

    private var kinds: [String] {
        Array(Set(events.map(\.kind))).sorted()
    }

    private var shown: [DiagnosticRecord] {
        (filter.isEmpty ? events : events.filter { $0.kind == filter }).reversed()
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Button("Previous day", systemImage: "chevron.left") { step(-1) }
                    Spacer()
                    Text(day).monospacedDigit()
                    Spacer()
                    Button("Next day", systemImage: "chevron.right") { step(1) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                LabeledContent("Points kept", value: pointsKept, format: .number)
                LabeledContent(
                    "Warm phases", value: events.filter { $0.kind == "warmPhaseBegan" }.count, format: .number)
                LabeledContent(
                    "Relaunches", value: events.filter { $0.kind == "appLaunched" && $0.detail == "location" }.count,
                    format: .number)
                LabeledContent("Minutes in coarse mode", value: Self.coarseMinutes(events, day: day), format: .number)
                Picker("Kind", selection: $filter) {
                    Text("All").tag("")
                    ForEach(kinds, id: \.self) { kind in
                        Text(kind).tag(kind)
                    }
                }
            }
            #if DEBUG
                TuningSection()
            #endif
            Section("Events") {
                if shown.isEmpty {
                    Text("No events yet").foregroundStyle(.secondary)
                }
                ForEach(shown) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(record.at, format: .dateTime.hour().minute().second())
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(record.kind).bold()
                        }
                        if !record.detail.isEmpty {
                            Text(record.detail).foregroundStyle(.secondary)
                        }
                        Text(Self.stateLine(record)).foregroundStyle(.tertiary)
                    }
                    .font(.footnote)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Export diagnostics", systemImage: "square.and.arrow.up") {
                    Task { await export() }
                }
            }
        }
        .sheet(item: $exported) { file in
            ShareLink(item: file.url) {
                Label("Share \(file.url.lastPathComponent)", systemImage: "square.and.arrow.up")
            }
            .padding()
            .presentationDetents([.fraction(0.25)])
        }
        .task(id: day) {
            events = await hub.diagnostics.events(onDay: day)
            pointsKept = (try? await hub.store.pointCount(onDay: day)) ?? 0
        }
    }

    private func step(_ days: Int) {
        guard let bounds = LocalDay.bounds(of: day, tz: TimeZone.current.identifier) else { return }
        let moment = bounds.start.addingTimeInterval(TimeInterval(days) * 86_400 + 3_600)
        day = LocalDay.key(for: moment, tz: TimeZone.current.identifier)
    }

    /// The seven days up to the chosen one.
    private func export() async {
        guard let bounds = LocalDay.bounds(of: day, tz: TimeZone.current.identifier) else { return }
        let from = bounds.start.addingTimeInterval(-Double(DiagnosticsLog.exportDays - 1) * 86_400)
        if let url = try? await hub.diagnostics.export(from: from, to: bounds.end) {
            exported = ExportedFile(url: url)
        }
    }

    nonisolated static func stateLine(_ record: DiagnosticRecord) -> String {
        var parts = [record.batteryPct.map { "\($0) %" } ?? "–", record.thermalState, record.appState]
        if record.lowPowerMode {
            parts.append("low power")
        }
        return parts.joined(separator: " · ")
    }

    /// Minutes between each `coarseModeEntered` and its `coarseModeLeft`, an open one
    /// counted to the end of the day or to now.
    nonisolated static func coarseMinutes(_ events: [DiagnosticRecord], day: String, now: Date = Date()) -> Int {
        var seconds: TimeInterval = 0
        var since: Date?
        for event in events.sorted(by: { $0.at < $1.at }) {
            switch event.kind {
            case "coarseModeEntered": since = since ?? event.at
            case "coarseModeLeft":
                if let start = since {
                    seconds += event.at.timeIntervalSince(start)
                }
                since = nil
            default: break
            }
        }
        if let start = since, let end = LocalDay.bounds(of: day, tz: TimeZone.current.identifier)?.end {
            seconds += min(end, now).timeIntervalSince(start)
        }
        return max(0, Int(seconds / 60))
    }
}

#if DEBUG
    /// The recorder's numbers, changed without a build; every change is logged.
    struct TuningSection: View {
        @State private var settings = RecorderSettings.load()
        @State private var gapSettings = GapSettings.load()

        var body: some View {
            Section("Tuning (Debug)") {
                Stepper(
                    "Warm phase: \(Int(settings.warmPhaseSeconds)) s", value: $settings.warmPhaseSeconds,
                    in: 60...1_800,
                    step: 60)
                Stepper(
                    "Stop radius: \(Int(settings.stopRadiusM)) m", value: $settings.stopRadiusM, in: 25...300, step: 25)
                Stepper(
                    "Fence radius: \(Int(settings.fenceRadiusM)) m", value: $settings.fenceRadiusM, in: 100...500,
                    step: 50)
                Stepper(
                    "Class hold: \(Int(settings.classHoldSeconds)) s", value: $settings.classHoldSeconds, in: 30...300,
                    step: 30)
                Stepper("Gap: \(Int(gapSettings.gapHours)) h", value: $gapSettings.gapHours, in: 1...12, step: 1)
                Button("Reset to defaults") {
                    settings = RecorderSettings()
                    gapSettings = GapSettings()
                }
            }
            .onChange(of: settings) { old, new in
                new.save()
                Task { await RecorderHub.shared.settingsChanged(from: old, to: new) }
            }
            .onChange(of: gapSettings) { _, new in
                new.save()
            }
        }
    }
#endif
