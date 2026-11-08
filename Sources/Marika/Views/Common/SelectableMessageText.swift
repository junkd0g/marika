import AppKit
import MarikaCore
import SwiftUI

/// Native selection makes partial copying, the Copy menu and ⌘C work consistently in chat.
struct SelectableMessageText: NSViewRepresentable {
    @Environment(\.openURL) private var openURL
    @Environment(\.conversationIsVisible) private var isActive
    let attributedText: NSAttributedString
    var wraps = true
    var fillsWidth = true
    var codeBlocks: [MessageCodeBlock] = []
    var onRun: ((ChatTerminalCommand) -> Void)?
    var runDisabled = false

    init(_ text: String, markdown: Bool = true, font: NSFont = .systemFont(ofSize: 14),
         color: NSColor = .labelColor, lineSpacing: CGFloat = 3, fillsWidth: Bool = true) {
        attributedText = Self.attributed(text, markdown: markdown, font: font, color: color, lineSpacing: lineSpacing)
        self.fillsWidth = fillsWidth
    }

    init(attributedText: NSAttributedString, wraps: Bool = true, codeBlocks: [MessageCodeBlock] = [],
         onRun: ((ChatTerminalCommand) -> Void)? = nil, runDisabled: Bool = false) {
        self.attributedText = attributedText
        self.wraps = wraps
        self.codeBlocks = codeBlocks; self.onRun = onRun; self.runDisabled = runDisabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(openURL: openURL) }

    func makeNSView(context: Context) -> NSTextView {
        let view = MessageTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.openURL = openURL
        // Do not replace the storage on unrelated updates: that would clear the selection.
        if view.attributedString() != attributedText {
            let selection = view.selectedRanges
            let appending = attributedText.string.hasPrefix(view.string)
            view.textStorage?.setAttributedString(attributedText)
            if appending { view.selectedRanges = selection }
        }
        if !isActive, let window = view.window, window.firstResponder === view { window.makeFirstResponder(nil) }
        (view as? MessageTextView)?.configure(codeBlocks: codeBlocks, onRun: onRun, disabled: runDisabled)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let container = nsView.textContainer, let manager = nsView.layoutManager else { return nil }
        let available = max(1, proposal.width ?? 760)
        let natural = max(1, ceil(attributedText.size().width))
        let width = wraps ? (fillsWidth ? available : min(available, natural)) : natural
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return CGSize(width: width, height: max(ceil(manager.usedRect(for: container).height), 1))
    }

    static func attributed(_ text: String, markdown: Bool, font: NSFont, color: NSColor, lineSpacing: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        let inline = markdown ? try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) : nil
        let result = NSMutableAttributedString(string: inline.map { String($0.characters) } ?? text,
                                               attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        if let inline {
            var offset = 0
            for run in inline.runs {
                let length = String(inline[run.range].characters).utf16.count
                let range = NSRange(location: offset, length: length)
                var traits: NSFontTraitMask = []
                if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { traits.insert(.boldFontMask) }
                if run.inlinePresentationIntent?.contains(.emphasized) == true { traits.insert(.italicFontMask) }
                if !traits.isEmpty { result.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: traits), range: range) }
                if run.inlinePresentationIntent?.contains(.code) == true {
                    result.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular),
                                          .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12)], range: range)
                }
                if let link = run.link { result.addAttribute(.link, value: link, range: range) }
                offset += length
            }
        }
        return result
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var openURL: OpenURLAction
        init(openURL: OpenURLAction) { self.openURL = openURL }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return true }
            openURL(url)
            return true
        }
    }
}
