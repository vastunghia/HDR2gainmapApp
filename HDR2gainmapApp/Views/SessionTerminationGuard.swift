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

/// "An export is running — stop it?" prompt, shared by the window-close and app-quit paths. Now that
/// exports run off the main thread the app stays fully usable meanwhile, so ⌘Q / ⌘W can arrive
/// mid-export. Returns `true` when the caller may proceed (no export running, or the user chose to
/// stop it — the caller then awaits `stopExportAndWait()` so no file write is cut short).
@MainActor
enum ExportInProgressPrompt {
    static func confirmStop(viewModel: MainViewModel) -> Bool {
        guard viewModel.isExporting else { return true }
        let alert = NSAlert()
        alert.messageText = "An export is in progress"
        alert.informativeText = "Stop it? Images already exported are kept; the image being processed "
            + "and the remaining ones are not written."
        alert.addButton(withTitle: "Stop Export")        // .alertFirstButtonReturn
        alert.addButton(withTitle: "Continue Exporting") // .alertSecondButtonReturn
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// App delegate that intercepts Quit (⌘Q / menu) while an export is running. Tone-mapping parameters
/// need no prompt: they are autosaved, and every window's view model flushes its pending autosave on
/// `NSApplication.willTerminateNotification`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Throttled, preference-gated; only surfaces an alert when a newer version exists.
        UpdateChecker.checkAutomatically()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel = SessionCoordinator.shared.activeViewModel else { return .terminateNow }

        guard viewModel.isExporting else { return .terminateNow }

        // A running export: stop it and wait for it to wind down, so no file write is cut short.
        guard ExportInProgressPrompt.confirmStop(viewModel: viewModel) else { return .terminateCancel }
        Task { @MainActor in
            await viewModel.stopExportAndWait()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Installs a window delegate on the session window to intercept the close button (⌘W / red button):
/// a running export is stopped first (after asking), and the pending autosave is written before the
/// window — and its view model — go away. Forwards every other delegate message to SwiftUI's
/// original delegate so window behavior is unaffected.
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
            guard let viewModel else { return true }

            // A running export first: stop it and wait, then re-run the close.
            if viewModel.isExporting {
                guard ExportInProgressPrompt.confirmStop(viewModel: viewModel) else { return false }
                Task { @MainActor [weak sender] in
                    await viewModel.stopExportAndWait()
                    sender?.performClose(nil)
                }
                return false
            }

            // Write pending parameter changes now: the view model goes away with the window.
            viewModel.flushAutosave()
            return true
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
