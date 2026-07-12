import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            ConversationView()
                .tabItem { Label("Conversation", systemImage: "bubble.left.and.bubble.right") }
            MonitorView()
                .tabItem { Label("Monitor", systemImage: "gauge.with.dots.needle.67percent") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

/// Umbrella tab for the three observation surfaces (Signal, Metrics,
/// Diagnostics). Three top-level tabs instead of five keeps the portrait
/// tab bar from overflowing into a sideways-scrolling More item.
///
/// The panes are swapped with a `switch`, not stacked, so each pane's
/// onAppear/onDisappear visibility gating (SignalAnalyzer.setEnabled,
/// MetricsStore.setVisible) keeps working exactly as it did when they
/// were separate tabs.
private struct MonitorView: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case signal = "Signal"
        case metrics = "Metrics"
        case diagnostics = "Diagnostics"
        var id: String { rawValue }
    }

    @AppStorage(AppSettings.monitorPaneKey) private var pane: Pane = .signal

    var body: some View {
        VStack(spacing: 0) {
            Picker("Monitor pane", selection: $pane) {
                ForEach(Pane.allCases) { pane in
                    Text(pane.rawValue).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.thinMaterial)
            switch pane {
            case .signal:
                SignalView()
            case .metrics:
                MetricsView()
            case .diagnostics:
                DiagnosticsView()
            }
        }
    }
}
