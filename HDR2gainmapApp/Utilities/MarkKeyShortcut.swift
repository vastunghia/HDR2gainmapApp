import SwiftUI
import AppKit

/// Routes the plain "M" key to a callback (used to mark / unmark the current image), mirroring
/// `ArrowKeyNavigation`'s local-monitor approach. Ignores the key while editing text (e.g. the
/// filename-suffix field) and when command/control/option are held, so it doesn't hijack typing
/// or real shortcuts.
struct MarkKeyShortcut: ViewModifier {
    let onMark: () -> Void

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    // Let text fields/views handle the key themselves.
                    if NSApp.keyWindow?.firstResponder is NSText {
                        return event
                    }
                    // Only a bare "m"/"M" (Shift allowed); ignore Cmd/Ctrl/Opt combinations.
                    let blocking: NSEvent.ModifierFlags = [.command, .control, .option]
                    guard event.modifierFlags.intersection(blocking).isEmpty,
                          event.charactersIgnoringModifiers?.lowercased() == "m" else {
                        return event
                    }
                    onMark()
                    return nil
                }
            }
            .onDisappear {
                if let m = monitor {
                    NSEvent.removeMonitor(m)
                    monitor = nil
                }
            }
    }
}

extension View {
    func markKeyShortcut(onMark: @escaping () -> Void) -> some View {
        modifier(MarkKeyShortcut(onMark: onMark))
    }
}
