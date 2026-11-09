import AppKit
import SwiftUI

/// Observe wheel clicks within a region without intercepting left clicks or scrolling.
struct MiddleClickTarget: NSViewRepresentable {
    var action: () -> Void

    func makeNSView(context: Context) -> TargetView { TargetView(action: action) }
    func updateNSView(_ view: TargetView, context: Context) { view.action = action }
    static func dismantleNSView(_ view: TargetView, coordinator: ()) { view.stopMonitoring() }

    final class TargetView: NSView {
        var action: () -> Void
        private var monitor: Any?
        init(action: @escaping () -> Void) { self.action = action; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window, event.buttonNumber == 2,
                          !self.isHiddenOrHasHiddenAncestor,
                          self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                          self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return false }
                    self.action()
                    return true
                }
                return handled ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
    }
}
