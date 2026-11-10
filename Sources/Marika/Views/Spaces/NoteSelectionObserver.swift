import AppKit
import MarikaCore
import SwiftUI

/// Observe the existing native field editor; retain its selection, undo and input-method behavior.
struct NoteSelectionObserver: NSViewRepresentable {
    let focusedBlock: UUID?
    let blocks: [SpaceNoteBlock]
    let onSelection: (NoteTextSelection?) -> Void
    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) {
        view.focusedBlock = focusedBlock; view.blocks = blocks; view.onSelection = onSelection
        DispatchQueue.main.async { [weak view] in view?.capture() }
    }
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.stop() }

    final class ObserverView: NSView {
        var focusedBlock: UUID?
        var blocks: [SpaceNoteBlock] = []
        var onSelection: ((NoteTextSelection?) -> Void)?
        private var observers: [NSObjectProtocol] = []
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            for name in [NSTextView.didChangeSelectionNotification, NSText.didChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { DispatchQueue.main.async { [weak self] in self?.capture() } }
                })
            }
        }
        func capture() {
            guard !isHiddenOrHasHiddenAncestor, let window, let blockID = focusedBlock,
                  let block = blocks.first(where: { $0.id == blockID }),
                  let editor = window.firstResponder as? NSTextView, editor.isFieldEditor, !editor.hasMarkedText(),
                  let field = editor.delegate as? NSView, field.window === window,
                  bounds.contains(convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), from: field)) else { return }
            let range = editor.selectedRange()
            if editor.string == block.text, range.length > 0 {
                onSelection?(NoteTextSelection(blockID: blockID, sourceText: block.text, range: range))
            } else { onSelection?(nil) }
        }
        func stop() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        }
    }
}
