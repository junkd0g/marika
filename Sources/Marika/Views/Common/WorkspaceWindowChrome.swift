import AppKit
import SwiftUI

/// The workspace supplies its own tabs and controls. NavigationSplitView can recreate
/// an empty native toolbar during layout/full-screen changes, so keep it hidden.
struct WorkspaceWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ view: ChromeView, context: Context) { view.apply() }
    static func dismantleNSView(_ view: ChromeView, coordinator: ()) { view.stopObserving() }

    final class ChromeView: NSView {
        private var observers: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            for name in [NSWindow.didUpdateNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply() }
                })
            }
            apply()
        }
        func apply() {
            guard let window else { return }
            if window.toolbar?.isVisible == true { window.toolbar?.isVisible = false }
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
        }
        func stopObserving() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }
    }
}
