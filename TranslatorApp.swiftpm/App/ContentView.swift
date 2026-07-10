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
        .background {
            // Invisible host for Apple Translation sessions (the framework
            // only vends them through a SwiftUI modifier). Lives at the root
            // so sessions survive tab switches.
            if #available(iOS 18.0, *) {
                TranslationBridgeView(broker: model.translationBroker)
            }
        }
    }
}
