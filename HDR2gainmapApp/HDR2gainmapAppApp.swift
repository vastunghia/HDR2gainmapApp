import SwiftUI
import AppKit

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
            AppInfoCommands()
            HelpMenuCommands()
        }

        Settings {
            PreferencesView()
        }
    }
}

// MARK: - GitHub repository

/// Single source of truth for the project's public links.
enum GitHubRepo {
    static let url = URL(string: "https://github.com/vastunghia/HDR2gainmapApp")!
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

/// App menu ▸ custom About panel (with a clickable GitHub link) + "Check for Updates…".
struct AppInfoCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About HDR2gainmapApp") {
                NSApplication.shared.orderFrontStandardAboutPanel(options: [
                    .credits: Self.creditsAttributedString
                ])
            }
        }
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                UpdateChecker.checkManually()
            }
        }
    }

    /// Credits shown in the standard About panel, carrying a tappable link to the repo.
    private static var creditsAttributedString: NSAttributedString {
        let result = NSMutableAttributedString(
            string: "Native macOS HDR → gain-map HEIC converter.\n\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        let link = NSAttributedString(
            string: "View on GitHub",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .link: GitHubRepo.url
            ]
        )
        result.append(link)
        return result
    }
}

/// Help menu ▸ links to the online README and the GitHub repository (replaces the
/// default, empty "HDR2gainmapApp Help" item that shows "Help isn't available").
struct HelpMenuCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("HDR2gainmapApp Help") {
                HelpWindowController.present()
            }
            Button("GitHub Repository") {
                NSWorkspace.shared.open(GitHubRepo.url)
            }
        }
    }
}
