import SwiftUI
import AppKit

/// Native NSWindow controller for the tone-mapping help panel. Mirrors
/// `ClippingLegendWindowController`: a non-modal auxiliary window the user can keep open while
/// adjusting the sliders. The content is static, so it needs no view model.
class TonemapHelpWindowController: NSWindowController {

    convenience init() {
        let screen = NSApp.mainWindow?.screen ?? NSScreen.main
        let availableHeight = (screen?.visibleFrame.height ?? 1000) - 40
        let defaultHeight: CGFloat = min(680, availableHeight)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: defaultHeight),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Understanding the Tone-Mapping Controls"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.minSize = NSSize(width: 420, height: 460)

        // Position near the main window (to its right), else centered.
        if let mainWindow = NSApp.mainWindow {
            let mainFrame = mainWindow.frame
            let newOrigin = NSPoint(x: mainFrame.maxX + 20, y: mainFrame.maxY - defaultHeight)
            window.setFrameOrigin(newOrigin)
        } else {
            window.center()
        }

        self.init(window: window)
        window.contentView = NSHostingView(rootView: TonemapHelpView())
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }
}

/// Static explanatory content for the tone-mapping parameters. Kept in sync with the
/// "Understanding the tone-mapping controls" section of README.md (single source of truth for the
/// prose).
struct TonemapHelpView: View {

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                intro

                Divider()

                section(
                    "Source Headroom & Target Headroom",
                    """
                    Two parameters shape the whole result: **Source Headroom** and **Target \
                    Headroom**. Everything else is just a way to set them.
                    """
                )

                section(
                    "Target Headroom",
                    """
                    Leave it at **1.0** in almost every case — it is not the creative control. \
                    You can tweak it to push the look into extreme/creative territory, but as a rule \
                    it stays put.
                    """
                )

                section(
                    "Source Headroom — the key control",
                    """
                    Source Headroom decides **how many pixels clip** (exceed white) in the \
                    tone-mapped SDR base, and that is the trade-off you are dialing in:

                    • **Few clipped pixels** (at the limit, zero) → a faithful reconstruction of the \
                    image, both in the SDR base and — above all — in the HDR result (SDR + gain map), \
                    but an SDR base that may look **too dark**.

                    • **More clipped pixels** → an SDR base that is **brighter** on average, but the \
                    detail in the brightest parts of the image gets distorted ("mangled") in both \
                    the SDR base and the HDR reconstruction.
                    """
                )

                section(
                    "The three methods: Peak Max · Percentile · Direct",
                    """
                    These three methods all do the **same one thing** — they set the Source \
                    Headroom parameter, and **nothing else**. They differ only in *how* you arrive \
                    at the value:

                    • **Peak Max** — derives it from the image's measured peak headroom via a ratio.
                    • **Percentile** — derives it from a luminance percentile of the image.
                    • **Direct** — you set the Source Headroom value directly.

                    For the same resulting Source Headroom the output is identical, whichever method \
                    you used. Pick whichever feels most intuitive.
                    """
                )

                section(
                    "The “Auto” button",
                    """
                    Auto picks the Source Headroom for you. It searches for the **lowest** Source \
                    Headroom that still keeps clipping within a small tolerance — specifically the \
                    fraction of pixels clipped in **any single R/G/B channel**, capped at the \
                    *per-channel clip tolerance* set in Preferences (default 1%).

                    Working per channel (rather than overall) curbs single-channel clipping — for \
                    example a clipped red channel that would otherwise tint the highlights. A lower \
                    tolerance yields a more faithful but darker SDR base; a higher tolerance yields a \
                    brighter base with more clipping.

                    The value Auto finds is written into the currently active method's parameter, so \
                    you can keep fine-tuning from there. **Auto all** runs the same search on every \
                    loaded image.
                    """
                )
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tone-Mapping Controls")
                .font(.title3.weight(.bold))
            Text("""
                 This app turns an HDR image into an SDR base image plus a *gain map*. On an HDR \
                 display the two recombine into the HDR look; on an SDR display you see the SDR \
                 base alone. How that SDR base is produced is what these controls govern.
                 """)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(Self.attributed(body))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Parses inline markdown (**bold**, *italic*) while preserving the original line breaks and
    /// whitespace, so the multi-line bodies with "•" bullets lay out as written.
    private static func attributed(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }
}
