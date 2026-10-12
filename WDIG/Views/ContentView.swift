import SwiftUI

/// The two screens of the first builds: the map of a day, and the recorder's status.
struct ContentView: View {
    @State private var hub = RecorderHub.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            Tab("Map", systemImage: "map") {
                DayMapScreen()
            }
            Tab("Status", systemImage: "waveform.path.ecg") {
                StatusScreen()
            }
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
