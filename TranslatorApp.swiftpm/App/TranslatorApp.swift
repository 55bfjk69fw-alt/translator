import SwiftUI
import UIKit

@main
struct TranslatorApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.signalAnalyzer)
                .environmentObject(model.metrics)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = AppSettings.keepScreenAwake
                }
        }
    }
}
