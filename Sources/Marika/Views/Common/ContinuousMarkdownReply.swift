import AppKit
import MarikaCore
import SwiftUI

struct MessageCodeBlock: Equatable {
    let header: NSRange
    let content: NSRange
    let text: String
    let command: ChatTerminalCommand?
}

/// One text storage owns the whole reply, including code. Buttons decorate it without splitting selection.
struct ContinuousMarkdownReply: View {
    let blocks: [MarkdownBlock]
    var onRun: ((ChatTerminalCommand) -> Void)?
    var runDisabled = false

    var body: some View {
        let rendered = render()
        SelectableMessageText(attributedText: rendered.0, codeBlocks: rendered.1, onRun: onRun, runDisabled: runDisabled)
    }

    private func render() -> (NSAttributedString, [MessageCodeBlock]) {
        let result = NSMutableAttributedString()
        var codeBlocks: [MessageCodeBlock] = []
        func inline(_ text: String, font: NSFont = .systemFont(ofSize: 14), color: NSColor = .labelColor,
                    indent: CGFloat = 0, hanging: CGFloat = 0, spacing: CGFloat = 10, markdown: Bool = true) {
            let value = NSMutableAttributedString(attributedString: SelectableMessageText.attributed(text + "\n", markdown: markdown,
                font: font, color: color, lineSpacing: 3))
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3; style.paragraphSpacing = spacing
            style.firstLineHeadIndent = indent; style.headIndent = indent + hanging
            value.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: value.length))
            result.append(value)
        }
        for block in blocks {
            switch block {
            case .heading(let level, let text):
                inline(text, font: .systemFont(ofSize: level == 1 ? 19 : level == 2 ? 16 : 14, weight: .semibold))
            case .paragraph(let text): inline(text)
            case .list(let items):
                for (index, item) in items.enumerated() {
                    let marker = item.checked.map { $0 ? "☑" : "☐" } ?? item.marker
                    inline(marker + " " + item.text, indent: CGFloat(item.depth) * 18, hanging: 18,
                           spacing: index == items.count - 1 ? 10 : 4)
                }
            case .quote(let text): inline(text, color: .secondaryLabelColor, indent: 12)
            case .image(let alt, _): inline(alt)
            case .rule: inline("────────────", color: .separatorColor)
            case .table(let header, let rows):
                inline(header.joined(separator: "\t"), font: .monospacedSystemFont(ofSize: 12, weight: .semibold), spacing: 4)
                for row in rows { inline(row.joined(separator: "\t"), font: .monospacedSystemFont(ofSize: 12, weight: .regular), spacing: 4) }
            case .code(let language, let text):
                let headerStart = result.length
                inline(language.isEmpty ? "code" : language, font: .systemFont(ofSize: 11), color: .secondaryLabelColor,
                       indent: 10, spacing: 8, markdown: false)
                let headerRange = NSRange(location: headerStart, length: result.length - headerStart)
                let contentStart = result.length
                let value = NSMutableAttributedString(string: text + "\n", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor])
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 2; style.firstLineHeadIndent = 10; style.headIndent = 10; style.tailIndent = -10
                style.lineBreakMode = .byCharWrapping
                value.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: value.length))
                let highlighted = SyntaxHighlighter.highlight(text, language: language)
                var offset = 0
                for run in highlighted.runs {
                    let count = String(highlighted[run.range].characters).utf16.count
                    if let color = run.swiftUI.foregroundColor {
                        value.addAttribute(.foregroundColor, value: NSColor(color), range: NSRange(location: offset, length: count))
                    }
                    offset += count
                }
                result.append(value)
                codeBlocks.append(MessageCodeBlock(header: headerRange, content: NSRange(location: contentStart, length: value.length),
                                                   text: text, command: onRun == nil ? nil : ChatTerminalCommand(language: language, text: text)))
                inline("", spacing: 4, markdown: false)
            }
        }
        return (result, codeBlocks)
    }
}

final class MessageTextView: NSTextView {
    private var blocks: [MessageCodeBlock] = []
    private var run: ((ChatTerminalCommand) -> Void)?
    private var buttons: [NSButton] = []

    override func accessibilityChildren() -> [Any]? {
        (super.accessibilityChildren() ?? []) + buttons
    }

    func configure(codeBlocks: [MessageCodeBlock], onRun: ((ChatTerminalCommand) -> Void)?, disabled: Bool) {
        run = onRun
        if codeBlocks != blocks {
            buttons.forEach { $0.removeFromSuperview() }; buttons.removeAll()
            blocks = codeBlocks
            for (index, block) in blocks.enumerated() {
                let copy = NSButton(title: "Copy", image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)!,
                                    target: self, action: #selector(copyCode(_:)))
                copy.tag = index; copy.setAccessibilityLabel("Copy code block")
                buttons.append(copy); addSubview(copy)
                if block.command != nil {
                    let play = NSButton(title: "Run", image: NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)!,
                                        target: self, action: #selector(runCode(_:)))
                    play.tag = index; play.setAccessibilityLabel("Run command in Terminal")
                    buttons.append(play); addSubview(play)
                }
            }
            for button in buttons { button.bezelStyle = .inline; button.controlSize = .small; button.font = .systemFont(ofSize: 11) }
        }
        for button in buttons where button.action == #selector(runCode(_:)) {
            button.isEnabled = !disabled
            button.toolTip = disabled ? "Wait for the agent to finish before running this command" : "Run this block in a new Terminal tab"
        }
        needsLayout = true; needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard let manager = layoutManager, let container = textContainer else { return }
        for button in buttons {
            let block = blocks[button.tag]
            guard NSMaxRange(block.header) <= (string as NSString).length else { button.isHidden = true; continue }
            button.isHidden = false
            let glyphs = manager.glyphRange(forCharacterRange: block.header, actualCharacterRange: nil)
            let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
            let copy = button.action == #selector(copyCode(_:))
            button.frame = CGRect(x: max(0, bounds.width - (copy ? 68 : 132)), y: rect.minY - 3, width: 60, height: 22)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let manager = layoutManager, let container = textContainer {
            NSColor.labelColor.withAlphaComponent(0.04).setFill()
            for block in blocks {
                let range = NSUnionRange(block.header, block.content)
                guard NSMaxRange(range) <= (string as NSString).length else { continue }
                let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
                NSBezierPath(roundedRect: CGRect(x: 0, y: rect.minY - 5, width: bounds.width, height: rect.height + 10),
                             xRadius: 9, yRadius: 9).fill()
            }
        }
        super.draw(dirtyRect)
    }

    @objc private func copyCode(_ sender: NSButton) {
        guard blocks.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(blocks[sender.tag].text, forType: .string)
    }

    @objc private func runCode(_ sender: NSButton) {
        guard blocks.indices.contains(sender.tag), let command = blocks[sender.tag].command else { return }
        run?(command)
    }
}
