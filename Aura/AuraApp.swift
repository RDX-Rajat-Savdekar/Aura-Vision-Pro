import SwiftUI

@main
struct AuraApp: App {
    // Shared models for the app lifetime.
    @StateObject private var micMonitor = MicrophoneMonitor()
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .environmentObject(micMonitor)
        }
    }
}
