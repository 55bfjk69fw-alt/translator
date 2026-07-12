import SwiftUI
import UIKit

@main
struct TranslatorApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.transcript)
                .environmentObject(model.signalAnalyzer)
                .environmentObject(model.metrics)
                .onAppear {
                    model.applyIdleTimerPolicy()
                }
        }
        // iOS resets isIdleTimerDisabled behind our back on deactivation
        // (app switch, incoming call, Siri), so the flag must be reasserted
        // on every return to the foreground — see applyIdleTimerPolicy.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.applyIdleTimerPolicy()
            }
        }
    }
}
