import SwiftUI

@main
struct HDR2gainmapApp: App {
    // Intercepts Quit to offer exporting unsaved settings first (window-close is handled per-window
    // by SessionWindowGuard). See SessionTerminationGuard.swift.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            SettingsProfileCommands()
        }

        Settings {
            PreferencesView()
        }
    }
}

// MARK: - Focused value plumbing for menu commands

/// Lets `.commands` reach the view model of the frontmost window (each `WindowGroup`
/// window owns its own `MainViewModel`).
extension FocusedValues {
    var mainViewModel: MainViewModel? {
        get { self[MainViewModelFocusedKey.self] }
        set { self[MainViewModelFocusedKey.self] = newValue }
    }
}

private struct MainViewModelFocusedKey: FocusedValueKey {
    typealias Value = MainViewModel
}

/// File ▸ Export/Import Settings, acting on the frontmost window's view model.
struct SettingsProfileCommands: Commands {
    @FocusedValue(\.mainViewModel) private var viewModel

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Export Settings…") {
                viewModel?.exportSettingsProfile()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(viewModel == nil || (viewModel?.images.isEmpty ?? true))

            Button("Import Settings…") {
                viewModel?.importSettingsProfile()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(viewModel == nil)
        }
    }
}
