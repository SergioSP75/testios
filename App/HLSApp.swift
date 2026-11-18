import SwiftUI
import HLSCore

// Punto de entrada de la app iOS.
@main
struct HLSApp: App {
    @StateObject private var store = PlaylistStore()
    @StateObject private var themes = ThemeStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(themes)
                .task { RemoteControl.shared.start(store: store) }
        }
    }
}
