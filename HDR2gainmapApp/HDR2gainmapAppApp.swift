import SwiftUI

@main
struct HDR2gainmapApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()   // la tua view principale
        }

        Settings {
            PreferencesView()
        }
    }
}
