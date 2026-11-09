import AppKit
import SwiftUI

/// Keep native mouse tracking on the selectable part of a tab. The close button
/// and context menu remain SwiftUI controls, with their normal accessibility.
struct BrowserTabInteraction: NSViewRepresentable {
    let pageID: UUID
    let title: String
    let select: () -> Void
    let close: () -> Void
    let move: (UUID, Bool) -> Bool

    func makeNSView(context: Context) -> TabMouseView { TabMouseView() }
    func updateNSView(_ view: TabMouseView, context: Context) {
        view.pageID = pageID; view.title = title
        view.select = select; view.close = close; view.move = move
    }
    static func dismantleNSView(_ view: TabMouseView, coordinator: ()) { view.stopMonitoring() }

    final class TabMouseView: NSView, NSDraggingSource {
        var pageID = UUID()
        var title = ""
        var select: (() -> Void)?
        var close: (() -> Void)?
        var move: ((UUID, Bool) -> Bool)?
        private var monitor: Any?
        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.string])
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, event.window === self.window else { return }
                    let point = self.convert(event.locationInWindow, from: nil)
                    if event.type == .otherMouseUp, event.buttonNumber == 2,
                       !self.isHiddenOrHasHiddenAncestor, self.bounds.contains(point), self.visibleRect.contains(point) { self.close?() }
                }
                return event
            }
        }
        func stopMonitoring() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
        override func hitTest(_ point: NSPoint) -> NSView? {
            if let event = NSApp.currentEvent, event.type == .rightMouseDown || event.type == .rightMouseUp { return nil }
            return super.hitTest(point)
        }
        override func otherMouseDown(with event: NSEvent) {}
        override func mouseDown(with event: NSEvent) {
            select?()
            let start = event.locationInWindow
            while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
                if next.type == .leftMouseUp { return }
                if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) < 4 { continue }
                let item = NSDraggingItem(pasteboardWriter: pageID.uuidString as NSString)
                let preview = NSImage(size: NSSize(width: 160, height: 30), flipped: false) { rect in
                    NSColor.windowBackgroundColor.setFill(); NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
                    (self.title as NSString).draw(in: rect.insetBy(dx: 10, dy: 7), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
                    return true
                }
                item.setDraggingFrame(NSRect(origin: convert(start, from: nil), size: preview.size), contents: preview)
                beginDraggingSession(with: [item], event: next, source: self)
                return
            }
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }
        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            guard let text = sender.draggingPasteboard.string(forType: .string), let id = UUID(uuidString: text), id != pageID else { return [] }
            return .move
        }
        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            guard let text = sender.draggingPasteboard.string(forType: .string), let id = UUID(uuidString: text) else { return false }
            return move?(id, convert(sender.draggingLocation, from: nil).x > bounds.midX) ?? false
        }
    }
}
