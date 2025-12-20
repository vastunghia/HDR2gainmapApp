import SwiftUI

@main
struct HDR2gainmapApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        
        Settings {
            PreferencesView()
        }
    }
}
