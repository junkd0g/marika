import AppKit
import SwiftUI

/// Native event observation also sees clicks inside WKWebView and editor subviews.
struct WorkspacePaneFocus: NSViewRepresentable {
    var isVisible: Bool
    var onFocus: () -> Void

    func makeNSView(context: Context) -> FocusRegion { FocusRegion() }
    func updateNSView(_ view: FocusRegion, context: Context) {
        view.isEnabled = isVisible
        view.onFocus = onFocus
    }
    static func dismantleNSView(_ view: FocusRegion, coordinator: ()) { view.stop() }

    final class FocusRegion: NSView {
        var isEnabled = false
        var onFocus: (() -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, self.isEnabled, event.window === self.window,
                          !self.isHiddenOrHasHiddenAncestor else { return }
                    if event.type == .keyDown {
                        // Tab focus can move into a pane without a pointer click.
                        if let responder = self.window?.firstResponder as? NSView,
                           self.bounds.contains(self.convert(responder.convert(responder.visibleRect.center, to: nil), from: nil)),
                           self.visibleRect.contains(self.convert(responder.convert(responder.visibleRect.center, to: nil), from: nil)) {
                            self.onFocus?()
                        }
                    } else if self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                              self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) {
                        self.onFocus?()
                    }
                }
                return event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
