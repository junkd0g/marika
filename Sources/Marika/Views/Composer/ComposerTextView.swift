import AppKit
import SwiftUI

/// The prompt field. Wraps `NSTextView` because `TextEditor` can't tell Return from
/// Shift-Return reliably or take a pasted image, and both matter here.
struct ComposerTextView: NSViewRepresentable {
    enum Key {
        case up
        case down
        case tab
        case escape
    }

    @Binding var text: String
    var placeholder: String
    var isActive = true
    /// Changing this moves keyboard focus into the field.
    var focusToken: AnyHashable
    var onSubmit: () -> Void
    var onPasteImage: (Data) -> Void
    /// Return true if the key was used, for example to drive the command list.
    var onKey: (Key) -> Bool

    private static let minHeight: CGFloat = 22
    private static let maxHeight: CGFloat = 190

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PromptTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .systemFont(ofSize: 13.5)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.placeholder = placeholder
        textView.onPasteImage = onPasteImage

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.onPasteImage = onPasteImage
        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
            textView.needsDisplay = true
        }
        if !isActive {
            context.coordinator.focusToken = nil
            textView.cancelFocusRequest()
            if let window = textView.window, window.firstResponder === textView { window.makeFirstResponder(nil) }
        }
        textView.composerActive = isActive
        if isActive && context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            textView.requestFocus()
        }
    }

    // SwiftUI proposes the final available width here, after the sidebar and inspector
    // have been laid out. Measuring without writing SwiftUI state avoids a feedback loop
    // between AppKit's document frame and the containing split view.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: min(Self.maxHeight, max(Self.minHeight, Self.textHeight(text, width: width))))
    }

    fileprivate static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13.5)])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let lastLine = manager.extraLineFragmentTextContainer === container ? manager.extraLineFragmentRect.maxY : 0
        return ceil(max(manager.usedRect(for: container).maxY, lastLine)) + 4
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: PromptTextView?
        var focusToken: AnyHashable?

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard parent.isActive else { return true }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // Shift-Return adds a line. Return alone sends.
                if (textView as? PromptTextView)?.lastKeyModifiers.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.moveUp(_:)):
                return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onKey(.down)
            case #selector(NSResponder.insertTab(_:)):
                return parent.onKey(.tab)
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onKey(.escape)
            default:
                return false
            }
        }

    }
}

final class PromptTextView: NSTextView {
    var composerActive = true
    override var acceptsFirstResponder: Bool { composerActive && super.acceptsFirstResponder }
    override var canBecomeKeyView: Bool { composerActive && super.canBecomeKeyView }
    var placeholder = ""
    var onPasteImage: ((Data) -> Void)?
    private(set) var lastKeyModifiers: NSEvent.ModifierFlags = []
    private var wantsFocus = false

    /// Takes keyboard focus now, or as soon as the view joins a window. A new session's field
    /// asks before it has one, and that request must not be lost.
    func requestFocus() {
        wantsFocus = true
        DispatchQueue.main.async { [weak self] in self?.applyPendingFocus() }
    }

    func cancelFocusRequest() { wantsFocus = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPendingFocus()
    }

    private func applyPendingFocus() {
        guard wantsFocus, let window else { return }
        wantsFocus = !window.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        lastKeyModifiers = event.modifierFlags
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        // Text wins, because rich text copied from elsewhere often carries an image version too.
        if pasteboard.string(forType: .string) == nil,
            let image = NSImage(pasteboard: pasteboard),
            let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        {
            onPasteImage?(png)
            return
        }
        pasteAsPlainText(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13.5),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        NSAttributedString(string: placeholder, attributes: attributes)
            .draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height))
    }
}
