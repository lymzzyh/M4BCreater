import SwiftUI

@main
struct M4BCreaterApp: App {
    @StateObject private var coordinator = ConversionCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
                .frame(minWidth: 1180, minHeight: 760)
        }
        .windowStyle(.titleBar)

        Settings {
            SettingsView()
                .environmentObject(coordinator)
                .frame(width: 620, height: 420)
        }
    }
}
