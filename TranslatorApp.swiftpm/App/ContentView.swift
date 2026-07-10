import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            ConversationView()
                .tabItem { Label("Conversation", systemImage: "bubble.left.and.bubble.right") }
            SignalView()
                .tabItem { Label("Signal", systemImage: "waveform.path.ecg") }
            DiagnosticsView()
                .tabItem { Label("Diagnostics", systemImage: "waveform.badge.magnifyingglass") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
