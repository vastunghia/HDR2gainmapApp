import SwiftUI
import AppKit

/// Native window hosting the in-app Help (rendered from the bundled `README.md`). Mirrors
/// `TonemapHelpWindowController`: a non-modal auxiliary window with static content (no view model).
/// Kept alive across opens via a static reference, since the menu command is a value-type `Commands`.
final class HelpWindowController: NSWindowController {

    private static var shared: HelpWindowController?

    /// Opens the Help window, reusing the existing one if already created.
    static func present() {
        if shared == nil {
            shared = HelpWindowController()
        }
        shared?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    convenience init() {
        let screen = NSApp.mainWindow?.screen ?? NSScreen.main
        let availableHeight = (screen?.visibleFrame.height ?? 1000) - 40
        let defaultHeight: CGFloat = min(820, availableHeight)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: defaultHeight),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "HDR2gainmapApp Help"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.minSize = NSSize(width: 520, height: 480)

        // Position near the main window (to its right), else centered.
        if let mainWindow = NSApp.mainWindow {
            let mainFrame = mainWindow.frame
            window.setFrameOrigin(NSPoint(x: mainFrame.maxX + 20, y: mainFrame.maxY - defaultHeight))
        } else {
            window.center()
        }

        self.init(window: window)
        window.contentView = NSHostingView(rootView: HelpView())
    }
}
