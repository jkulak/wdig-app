import SwiftUI

/// The first screen until the day map arrives: is recording alive, when was the last fix,
/// how many points are there, and what the recorder did lately.
struct ContentView: View {
    @State private var hub = RecorderHub.shared
    @Environment(\.scenePhase) private var scenePhase

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
            .navigationTitle("WDIG")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                hub.sceneBecameActive()
            }
        }
    }
}

#Preview {
    ContentView()
}
