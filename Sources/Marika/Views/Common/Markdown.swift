import AppKit
import MarikaCore
import SwiftUI

extension EnvironmentValues {
    /// The project a message belongs to, for resolving relative file links.
    @Entry var projectRoot: URL?
}

/// Decides what clicking a link in agent output does. That text is untrusted, so a click must not
/// be able to run anything through a link: opening a script can execute it, and a custom URL scheme can drive
/// another app. Web links open normally, file links only reveal the file, and the rest do nothing.
private func handleLink(_ url: URL, projectRoot: URL?) -> OpenURLAction.Result {
    switch url.scheme?.lowercased() {
    case "http", "https", "mailto":
        return .systemAction
    case nil, "file":
        guard let target = FilePath.linkTarget(url, relativeTo: projectRoot),
            FileManager.default.fileExists(atPath: target.path)
        else { return .discarded }
        NSWorkspace.shared.activateFileViewerSelecting([target])
        return .handled
    default:
        return .discarded
    }
}

/// Renders agent output. Written by hand so the app has no third-party dependencies.
struct MarkdownView: View {
    @Environment(\.projectRoot) private var projectRoot
    let text: String
    var documentURL: URL?
    var parsedBlocks: [MarkdownBlock]?
    var onOpenLink: ((URL) -> OpenURLAction.Result)?
    var onRunCommand: ((ChatTerminalCommand) -> Void)?
    var runCommandsDisabled = false
    var nativeSelection = false

    var body: some View {
        let blocks = parsedBlocks ?? MarkdownParser.parse(text)
        let anchors = MarkdownParser.headingAnchors(in: blocks)
        let content = ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
            if documentURL != nil { view(for: block).id(anchors[index] ?? "markdown-block-\(index)") }
            else { view(for: block) }
        }
        Group {
            if nativeSelection, documentURL == nil {
                ContinuousMarkdownReply(blocks: blocks, onRun: onRunCommand, runDisabled: runCommandsDisabled)
            }
            else if documentURL == nil { VStack(alignment: .leading, spacing: 10) { content } }
            else { LazyVStack(alignment: .leading, spacing: 16) { content } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in onOpenLink?(url) ?? handleLink(url, projectRoot: projectRoot) })
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text, size: headingSize(level), bold: true)
                .padding(.top, level <= 2 ? 10 : 4)
        case .paragraph(let text):
            inline(text, lineSpacing: documentURL == nil ? 3 : 5)
        case .code(let language, let text):
            CodeBlock(language: language, text: text, onRunCommand: onRunCommand, runDisabled: runCommandsDisabled, nativeSelection: nativeSelection)
        case .list(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: nativeSelection ? .top : .firstTextBaseline, spacing: 7) {
                        if let checked = item.checked {
                            Image(systemName: checked ? "checkmark.square.fill" : "square")
                                .foregroundStyle(checked ? Color.accentColor : .secondary)
                                .accessibilityLabel(checked ? "Completed task" : "Incomplete task")
                        } else {
                            Text(item.marker).foregroundStyle(.secondary).monospacedDigit()
                                .frame(minWidth: 12, alignment: .trailing)
                        }
                        inline(item.text)
                    }
                    .font(Theme.body)
                    .padding(.leading, CGFloat(item.depth) * 18)
                }
            }
        case .quote(let text):
            inline(text, secondary: true)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 2)
                }
        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows, nativeSelection: nativeSelection)
        case .rule:
            Divider().padding(.vertical, 2)
        case .image(let alt, let source):
            if let documentURL, let projectRoot {
                MarkdownImage(alt: alt, source: source, documentURL: documentURL, root: projectRoot)
            } else { inline(alt) }
        }
    }

    @ViewBuilder private func inline(_ text: String, size: CGFloat = 14, bold: Bool = false, secondary: Bool = false, lineSpacing: CGFloat = 3) -> some View {
        if nativeSelection {
            SelectableMessageText(text, font: .systemFont(ofSize: size, weight: bold ? .semibold : .regular),
                                  color: secondary ? .secondaryLabelColor : .labelColor, lineSpacing: lineSpacing)
        } else {
            InlineText(text).font(.system(size: size, weight: bold ? .semibold : .regular))
                .foregroundStyle(secondary ? .secondary : .primary).lineSpacing(lineSpacing)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        if documentURL != nil { return level == 1 ? 28 : level == 2 ? 22 : level == 3 ? 18 : 15 }
        return level == 1 ? 19 : level == 2 ? 16 : 14
    }
}

/// Inline emphasis, links and `code`.
struct InlineText: View {
    let source: String

    init(_ source: String) {
        self.source = source
    }

    var body: some View {
        Text(Self.attributed(source))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func attributed(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var attributed = try? AttributedString(markdown: source, options: options) else {
            return AttributedString(source)
        }
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .system(size: 12.5, design: .monospaced)
            attributed[run.range].backgroundColor = Theme.surface
        }
        return attributed
    }
}

struct CodeBlock: View {
    let language: String
    let text: String
    var onRunCommand: ((ChatTerminalCommand) -> Void)?
    var runDisabled = false
    var nativeSelection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if let onRunCommand, let command = ChatTerminalCommand(language: language, text: text) {
                    Button { onRunCommand(command) } label: { Label("Run", systemImage: "play.fill") }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                        .disabled(runDisabled)
                        .help(runDisabled ? "Wait for the agent to finish before running this command" : "Run this block in a new Terminal tab")
                        .accessibilityLabel("Run command in Terminal")
                }
                CopyButton(text: text)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                codeText
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
            }
        }
        .surface(cornerRadius: 10)
    }

    @ViewBuilder private var codeText: some View {
        if nativeSelection {
            let highlighted = SyntaxHighlighter.highlight(text, language: language)
            let value = NSMutableAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor])
            var offset = 0
            let _ = highlighted.runs.forEach { run in
                let length = String(highlighted[run.range].characters).utf16.count
                if let color = run.swiftUI.foregroundColor { value.addAttribute(.foregroundColor, value: NSColor(color), range: NSRange(location: offset, length: length)) }
                offset += length
            }
            SelectableMessageText(attributedText: value, wraps: false)
        } else {
            Text(SyntaxHighlighter.highlight(text, language: language)).font(Theme.code).lineSpacing(2).textSelection(.enabled).fixedSize()
        }
    }
}

private struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    var nativeSelection = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        cellText(cell, bold: true)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            cellText(cell)
                        }
                    }
                }
            }
            .padding(10)
        }
        .surface(cornerRadius: 10)
    }

    @ViewBuilder private func cellText(_ text: String, bold: Bool = false) -> some View {
        if nativeSelection { SelectableMessageText(text, font: .systemFont(ofSize: 12.5, weight: bold ? .semibold : .regular), fillsWidth: false) }
        else { InlineText(text).font(.system(size: 12.5, weight: bold ? .semibold : .regular)) }
    }
}

/// A deliberately small highlighter: comments, strings, numbers and common keywords. It covers
/// what helps when reading an agent's answer without bundling a grammar for every language.
enum SyntaxHighlighter {
    private static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "import", "struct", "class", "enum", "protocol",
        "extension", "guard", "switch", "case", "default", "try", "await", "async", "throw", "throws", "public", "private",
        "static", "self", "true", "false", "nil", "null", "none", "None", "True", "False", "def", "from", "as", "in", "not",
        "and", "or", "const", "function", "interface", "type", "export", "new", "this", "fn", "pub", "impl", "use", "mut",
        "package", "go", "defer", "with", "yield", "lambda", "elif", "do", "then", "fi", "done", "esac", "echo",
    ]
    private static let plainLanguages: Set<String> = ["text", "txt", "plain", "output", "log", "console"]

    static func highlight(_ code: String, language: String) -> AttributedString {
        var output = AttributedString(code)
        guard code.utf8.count < 60_000, !plainLanguages.contains(language.lowercased()) else { return output }
        let hashComments = ["py", "python", "sh", "bash", "zsh", "shell", "ruby", "rb", "yaml", "yml", "toml"]
            .contains(language.lowercased())

        apply(pattern: #"\b\d+(\.\d+)?\b"#, color: .purple, to: &output, in: code)
        apply(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#, color: .pink, to: &output, in: code) { keywords.contains($0) }
        apply(pattern: #""(\\.|[^"\\\n])*"|'(\\.|[^'\\\n])*'|`(\\.|[^`\\])*`"#, color: .green, to: &output, in: code)
        apply(pattern: hashComments ? #"#.*$"# : #"//.*$|/\*[\s\S]*?\*/"#, color: .secondary, to: &output, in: code)
        return output
    }

    private static func apply(
        pattern: String, color: Color, to output: inout AttributedString, in code: String,
        where predicate: ((String) -> Bool)? = nil
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
        for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let range = Range(match.range, in: code) else { continue }
            if let predicate, !predicate(String(code[range])) { continue }
            let lower = AttributedString.Index(range.lowerBound, within: output)
            let upper = AttributedString.Index(range.upperBound, within: output)
            if let lower, let upper { output[lower..<upper].foregroundColor = color }
        }
    }
}
