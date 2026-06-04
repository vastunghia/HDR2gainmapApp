import SwiftUI
import AppKit

/// Routes left/right arrow keys to callbacks, mirroring `EscapeToClose`'s local-monitor approach.
/// Does not steal the arrow keys while the user is editing text (e.g. the filename-suffix field),
/// so cursor movement keeps working there.
struct ArrowKeyNavigation: ViewModifier {
    let onLeft: () -> Void
    let onRight: () -> Void

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    // Let text fields/views handle arrows themselves (NSTextField uses an
                    // NSTextView field editor; both are NSText subclasses).
                    if NSApp.keyWindow?.firstResponder is NSText {
                        return event
                    }
                    switch event.keyCode {
                    case 123: onLeft();  return nil  // left arrow
                    case 124: onRight(); return nil  // right arrow
                    default:  return event
                    }
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
    func arrowKeyNavigation(onLeft: @escaping () -> Void, onRight: @escaping () -> Void) -> some View {
        modifier(ArrowKeyNavigation(onLeft: onLeft, onRight: onRight))
    }
}
