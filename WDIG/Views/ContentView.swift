import SwiftUI

/// The placeholder until the day map arrives: the one screen the scaffold shows.
struct ContentView: View {
    var body: some View {
        ContentUnavailableView("No days recorded yet", systemImage: "map")
    }
}

#Preview {
    ContentView()
}
