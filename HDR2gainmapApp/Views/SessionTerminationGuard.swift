import SwiftUI
import AppKit

/// Tracks the frontmost session's view model so the app-termination handler can reach it.
/// The app is effectively single-window; this holds the most recently active session.
@MainActor
final class SessionCoordinator {
    static let shared = SessionCoordinator()
    weak var activeViewModel: MainViewModel?
    private init() {}
}

/// Shared "save your tone-mapping parameters before closing?" prompt, used by both the window-close
/// and the app-quit paths. Shows the alert only when the session has unsaved, non-default parameters.
/// `onResolved(proceed)` is called with `true` when the caller may close/terminate (the user either
/// exported successfully or chose to discard) and `false` when it must abort (Cancel, or the save
/// panel was dismissed).
@MainActor
enum SessionExportPrompt {
    static func confirm(viewModel: MainViewModel, onResolved: @escaping (Bool) -> Void) {
        guard viewModel.hasUnsavedSettingsToExport() else { onResolved(true); return }

        let alert = NSAlert()
        alert.messageText = "Save your tone-mapping parameters before closing?"
        alert.informativeText = "You changed the tone-mapping parameters of one or more images. "
            + "Save them to a JSON profile so you can restore them in a later session?"
        alert.addButton(withTitle: "Save Tone-Mapping Parameters…") // .alertFirstButtonReturn
        alert.addButton(withTitle: "Don't Save")        // .alertSecondButtonReturn
        alert.addButton(withTitle: "Cancel")            // .alertThirdButtonReturn

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // The save panel is asynchronous; proceed only if a file was actually written.
            viewModel.exportSettingsProfile { saved in onResolved(saved) }
        case .alertSecondButtonReturn:
            onResolved(true)   // discard: close/quit without exporting
        default:
            onResolved(false)  // cancel: keep the session open
        }
    }
}

/// App delegate that intercepts Quit (⌘Q / menu) to offer exporting settings first.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Throttled, preference-gated; only surfaces an alert when a newer version exists.
        UpdateChecker.checkAutomatically()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel = SessionCoordinator.shared.activeViewModel,
              viewModel.hasUnsavedSettingsToExport() else {
            return .terminateNow
        }
        SessionExportPrompt.confirm(viewModel: viewModel) { proceed in
            NSApp.reply(toApplicationShouldTerminate: proceed)
        }
        return .terminateLater
    }
}

/// Installs a window delegate on the session window to intercept the close button (⌘W / red button)
/// and offer exporting settings first — without quitting the app. Forwards every other delegate
/// message to SwiftUI's original delegate so window behavior is unaffected.
struct SessionWindowGuard: NSViewRepresentable {
    let viewModel: MainViewModel

    func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { context.coordinator.ensureInstalled(on: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.viewModel = viewModel
        SessionCoordinator.shared.activeViewModel = viewModel
        DispatchQueue.main.async { context.coordinator.ensureInstalled(on: nsView.window) }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        weak var viewModel: MainViewModel?
        private weak var window: NSWindow?
        // `nonisolated(unsafe)`: only ever touched on the main thread (installed in `ensureInstalled`,
        // read by the nonisolated NSObject forwarding overrides below, which AppKit calls on main).
        nonisolated(unsafe) private weak var previousDelegate: NSWindowDelegate?
        private var forceClose = false

        init(viewModel: MainViewModel) { self.viewModel = viewModel }

        /// Make this object the window delegate (idempotent; re-asserts if SwiftUI reclaims it).
        func ensureInstalled(on window: NSWindow?) {
            guard let window else { return }
            self.window = window
            if window.delegate !== self {
                if !(window.delegate is Coordinator) { previousDelegate = window.delegate }
                window.delegate = self
            }
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if forceClose { return true }
            guard let viewModel, viewModel.hasUnsavedSettingsToExport() else { return true }
            SessionExportPrompt.confirm(viewModel: viewModel) { [weak self, weak sender] proceed in
                guard proceed, let self, let sender else { return }
                self.forceClose = true
                sender.close()
            }
            return false
        }

        // MARK: Forward all other delegate messages to SwiftUI's original delegate.
        // `nonisolated` to match NSObject's isolation for these overrides (AppKit calls them on main).
        nonisolated override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (previousDelegate?.responds(to: aSelector) ?? false)
        }
        nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
            (previousDelegate?.responds(to: aSelector) ?? false) ? previousDelegate : nil
        }
    }
}
