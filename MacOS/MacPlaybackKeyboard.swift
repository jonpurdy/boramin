import AppKit

/// Intercept unmodified seek keys only within the current playback host.
/// Resolve the view's window for every event because AVKit can reparent it for full screen.
@MainActor final class MacPlaybackKeyboard {
    private weak var view: NSView?
    private let seek: (Double) -> Void
    private var monitor: Any?

    init(view: NSView, seek: @escaping (Double) -> Void) {
        self.view = view
        self.seek = seek
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handle(event) == nil
            }
            return handled ? nil : event
        }
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard event.type == .keyDown, modifiers.isEmpty,
              let window = view?.window, window.isKeyWindow, event.window === window,
              window.attachedSheet == nil, !(window.firstResponder is NSTextView) else { return event }
        switch event.keyCode {
        case 123: seek(-10)
        case 124: seek(10)
        default: return event
        }
        return nil
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}
