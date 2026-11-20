import AppKit
import SwiftUI

/// Native tables consume Return before a parent SwiftUI key handler can see it.
/// Intercept file commands only inside this file area's key window, never in text editors or the sidebar.
struct FileKeyboard: NSViewRepresentable {
    let enabled: Bool
    let handle: (NSEvent) -> Bool

    func makeNSView(context: Context) -> Area { Area() }
    func updateNSView(_ view: Area, context: Context) { view.handle = handle; view.enabled = enabled }
    static func dismantleNSView(_ view: Area, coordinator: ()) { view.stop() }

    final class Area: NSView {
        var enabled = false
        var handle: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, window.isKeyWindow,
                      event.window === window, let responder = window.firstResponder,
                      !(responder is NSTextView), !(responder is NSTextField) else { return event }
                var inFileArea = self.enabled
                if let focused = responder as? NSView, !focused.bounds.isEmpty {
                    let area = self.convert(self.bounds, to: nil)
                    let rect = focused.convert(focused.bounds, to: nil)
                    inFileArea = area.contains(NSPoint(x: rect.midX, y: rect.midY))
                }
                guard inFileArea else { return event }
                return self.handle?(event) == true ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { stop() }
    }
}
