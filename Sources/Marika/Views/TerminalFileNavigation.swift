import AppKit
import CoreText
import MarikaCore
@preconcurrency import SwiftTerm

/// Intercepts a click only when it resolves to a real source file. Normal selection,
/// dragging, terminal mouse reporting and command input remain with SwiftTerm.
@MainActor final class TerminalFileNavigation: NSObject, @preconcurrency LocalProcessTerminalViewDelegate {
    weak var view: LocalProcessTerminalView?
    var directory: URL
    var roots: [URL]
    var isActive = true
    var open: (TerminalFileLink, URL, String) -> Void
    private var monitor: Any?
    private var mouseDown: NSPoint?
    private var dragged = false

    init(view: LocalProcessTerminalView, directory: URL, roots: [URL], open: @escaping (TerminalFileLink, URL, String) -> Void) {
        self.view = view; self.directory = directory; self.roots = roots; self.open = open
        super.init()
        view.processDelegate = self
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved]) { [weak self] event in
            let keep = MainActor.assumeIsolated { self.map { $0.handle(event) != nil } ?? true }
            return keep ? event : nil
        }
    }
    func invalidate() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if view?.processDelegate === self { view?.processDelegate = nil }
    }
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isActive, let view, event.window === view.window, !view.isHiddenOrHasHiddenAncestor,
              view.getTerminal().mouseMode == .off else { return event }
        let point = view.convert(event.locationInWindow, from: nil)
        guard view.bounds.contains(point) else { return event }
        if event.type == .leftMouseDown { mouseDown = point; dragged = false }
        if event.type == .leftMouseDragged { dragged = true }
        if event.type == .mouseMoved {
            if link(at: point) != nil { NSCursor.pointingHand.set() }
            return event
        }
        guard event.type == .leftMouseUp, event.clickCount == 1, !dragged,
              let origin = mouseDown, hypot(point.x - origin.x, point.y - origin.y) < 4,
              let (link, root, path) = link(at: point) else { return event }
        mouseDown = nil
        open(link, root, path)
        return nil
    }
    func link(at point: NSPoint) -> (TerminalFileLink, URL, String)? {
        guard let view else { return nil }
        let terminal = view.getTerminal()
        let height = view.getOptimalFrameSize().height / CGFloat(max(1, terminal.rows))
        let width = max(1, view.font.advancement(forGlyph: view.font.glyph(withName: "W")).width)
        let row = Int((view.bounds.maxY - point.y) / max(1, height))
        let column = Int(point.x / width)
        guard row >= 0, row < terminal.rows, column >= 0, column < terminal.cols,
              let line = terminal.getLine(row: row) else { return nil }
        let text = line.translateToString(trimRight: true, skipNullCellsFollowingWide: true, characterProvider: terminal.getCharacter)
        let prefix = line.translateToString(startCol: 0, endCol: column, skipNullCellsFollowingWide: true, characterProvider: terminal.getCharacter)
        let offset = (prefix as NSString).length
        for link in TerminalFileLink.find(in: text) where NSLocationInRange(offset, link.range) {
            if let target = link.resolved(relativeTo: directory, allowedRoots: roots) { return (link, target.root, target.path) }
        }
        return nil
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let url = URL(string: directory), url.isFileURL,
              url.host == nil || url.host == "localhost" else { return }
        self.directory = url
    }
    func processTerminated(source: TerminalView, exitCode: Int32?) {}
}
