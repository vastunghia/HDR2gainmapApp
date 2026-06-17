import SwiftUI
import AppKit

/// Makes the hosting window vertically resizable with a fixed width. The SwiftUI `Settings` scene is
/// created *without* `.resizable` in its style mask (no handle), and under
/// `.windowResizability(.contentMinSize)` the SwiftUI content frame only constrains the content, not
/// the window — so the window's width is unbounded and AppKit restores a stale auto-saved frame on
/// reopen. We therefore configure the backing `NSWindow` directly the moment the view attaches
/// (`viewDidMoveToWindow`): insert `.resizable`, lock the width (content min == max), leave the height
/// free above `minHeight`, and force the opening size to `width × initialHeight` (overriding any
/// restored frame). Must still be paired with `.windowResizability(.contentMinSize)` on the scene.
///
/// Resize hook based on https://stackoverflow.com/a/79532912 (Sweeper, CC BY-SA 4.0).
struct EnableWindowResize: NSViewRepresentable {
    let width: CGFloat
    let minHeight: CGFloat
    let initialHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = Helper()
        view.width = width
        view.minHeight = minHeight
        view.initialHeight = initialHeight
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Helper: NSView {
        var width: CGFloat = 0
        var minHeight: CGFloat = 0
        var initialHeight: CGFloat = 0
        private var configured = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !configured else { return }
            configured = true

            window.styleMask.insert(.resizable)
            // Lock the width (min == max); leave the height free above `minHeight`.
            window.contentMinSize = NSSize(width: width, height: minHeight)
            window.contentMaxSize = NSSize(width: width, height: 100_000)

            // Open at the desired content size, overriding any restored/auto-saved frame, keeping the
            // top-left corner anchored (macOS frames are bottom-left origin).
            let topLeftY = window.frame.maxY
            window.setContentSize(NSSize(width: width, height: initialHeight))
            var frame = window.frame
            frame.origin.y = topLeftY - frame.height
            window.setFrame(frame, display: true)
        }
    }
}

extension View {
    /// Makes the hosting window vertically resizable with a fixed `width`, a floor of `minHeight`, and
    /// an opening height of `initialHeight`. See `EnableWindowResize`. Pair with
    /// `.windowResizability(.contentMinSize)` on the scene.
    func enableWindowResize(width: CGFloat, minHeight: CGFloat, initialHeight: CGFloat) -> some View {
        background(EnableWindowResize(width: width, minHeight: minHeight, initialHeight: initialHeight))
    }
}
