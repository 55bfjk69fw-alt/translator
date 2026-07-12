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
/// This view owns the panes' shared NavigationStack; the switcher lives in
/// the navigation bar (a menu in the title position), because the floating
/// tab bar overlays raw content instead of insetting it — anything placed
/// at the top of the safe area ends up hidden underneath it.
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
        var icon: String {
            switch self {
            case .signal: return "waveform.path.ecg"
            case .metrics: return "chart.xyaxis.line"
            case .diagnostics: return "waveform.badge.magnifyingglass"
            }
        }
    }

    @AppStorage(AppSettings.monitorPaneKey) private var pane: Pane = .signal

    var body: some View {
        NavigationStack {
            Group {
                switch pane {
                case .signal:
                    SignalView()
                case .metrics:
                    MetricsView()
                case .diagnostics:
                    DiagnosticsView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    paneMenu
                }
            }
        }
    }

    private var paneMenu: some View {
        Menu {
            Picker("Monitor pane", selection: $pane) {
                ForEach(Pane.allCases) { pane in
                    Label(pane.rawValue, systemImage: pane.icon).tag(pane)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(pane.rawValue)
                    .font(.headline)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
        }
    }
}
