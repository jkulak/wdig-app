import SwiftUI

/// Is recording alive, when was the last fix, how many points are there, and what the
/// recorder did lately. In a Debug build it also makes and removes a month of demo data.
struct StatusScreen: View {
    @State private var hub = RecorderHub.shared
    @State private var demoBusy = false
    @State private var demoMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Tracking") {
                    Toggle("Tracking", isOn: $hub.trackingEnabled)
                    LabeledContent("State", value: hub.phaseText)
                    LabeledContent("Last fix") {
                        if let lastFixAt = hub.lastFixAt {
                            Text(lastFixAt, format: .dateTime.hour().minute().second())
                        } else {
                            Text("Never")
                        }
                    }
                    LabeledContent("Points today", value: hub.pointsToday, format: .number)
                    LabeledContent("Points total", value: hub.pointsTotal, format: .number)
                    LabeledContent("Location", value: hub.authorization)
                    if hub.authorization != "always" {
                        Button("Open Settings") {
                            hub.openSystemSettings()
                        }
                    }
                    if let storeError = hub.storeError {
                        Text(storeError).foregroundStyle(.red)
                    }
                }
                #if DEBUG
                    Section("Demo data") {
                        Button("Generate a demo month") {
                            runDemo { try await DemoMonth.generate(into: hub.store) }
                        }
                        .disabled(demoBusy)
                        Button("Remove demo data", role: .destructive) {
                            runDemo { try await DemoMonth.remove(from: hub.store) }
                        }
                        .disabled(demoBusy)
                        if let demoMessage {
                            Text(demoMessage).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                #endif
                Section("Recent events") {
                    if hub.events.isEmpty {
                        Text("No events yet").foregroundStyle(.secondary)
                    }
                    ForEach(hub.events) { record in
                        HStack(alignment: .firstTextBaseline) {
                            Text(record.at, format: .dateTime.hour().minute().second())
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(record.event.text)
                        }
                        .font(.footnote)
                    }
                }
            }
            .navigationTitle("Status")
        }
    }

    private func runDemo(_ work: @escaping @Sendable () async throws -> String) {
        demoBusy = true
        demoMessage = String(localized: "Working…")
        Task {
            do {
                demoMessage = try await work()
            } catch {
                demoMessage = error.localizedDescription
            }
            demoBusy = false
            await hub.refresh()
        }
    }
}
