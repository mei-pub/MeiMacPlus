import AppKit

/// Closes a window when the user presses Esc. Installs a local key monitor
/// for the window's lifetime; the returned token must be invalidated when
/// the window closes (windowWillClose).
enum WindowEscapeCloser {

    final class Token {
        let monitor: Any
        init(monitor: Any) { self.monitor = monitor }
        func invalidate() { NSEvent.removeMonitor(monitor) }
    }

    @discardableResult
    static func attach(to window: NSWindow) -> Token? {
        let token = Token(monitor: NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === window,
                  event.keyCode == 53, // Esc
                  event.modifierFlags.intersection(.deviceIndependentFlagsSet).subtracting(.capsLock).isEmpty
            else { return event }
            window.close()
            return nil
        })
        return token
    }
}
