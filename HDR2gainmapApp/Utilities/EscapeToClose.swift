import SwiftUI
import AppKit

struct EscapeToClose: ViewModifier {
    @State private var monitor: Any?
    
    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    // 53 = Escape on macOS
                    if event.keyCode == 53 {
                        NSApp.keyWindow?.performClose(nil)
                        return nil // swallow the event
                    }
                    return event
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
    func closeOnEscape() -> some View { modifier(EscapeToClose()) }
}
