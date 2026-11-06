import AppKit
import MarikaCore
import SwiftUI

extension EnvironmentValues {
    /// The project a message belongs to, for resolving relative file links.
    @Entry var projectRoot: URL?
}

/// Decides what clicking a link in agent output does. That text is untrusted, so a click must not
/// be able to run anything: opening a script can execute it, and a custom URL scheme can drive
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

/// The block structure of a Markdown message.
enum MarkdownBlock: Equatable {
    struct ListItem: Equatable {
        var depth: Int
        var marker: String
        var text: String
    }

    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String, text: String)
    case list([ListItem])
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule
}

enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        let lines = source.components(separatedBy: "\n")
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(language: language, text: body.joined(separator: "\n")))
            } else if trimmed.isEmpty {
                flushParagraph()
                index += 1
            } else if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
            } else if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let text = lines[index].trimmingCharacters(in: .whitespaces).dropFirst()
                    quoted.append(text.trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
            } else if listItem(line) != nil {
                flushParagraph()
                var items: [MarkdownBlock.ListItem] = []
                while index < lines.count {
                    if let item = listItem(lines[index]) {
                        items.append(item)
                        index += 1
                    } else if !items.isEmpty, lines[index].hasPrefix("  "),
                        !lines[index].trimmingCharacters(in: .whitespaces).isEmpty
                    {
                        // A wrapped continuation of the previous item.
                        items[items.count - 1].text += " " + lines[index].trimmingCharacters(in: .whitespaces)
                        index += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(items))
            } else if index + 1 < lines.count, trimmed.contains("|"), isTableDivider(lines[index + 1]) {
                flushParagraph()
                let header = tableCells(trimmed)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, lines[index].contains("|"),
                    !lines[index].trimmingCharacters(in: .whitespaces).isEmpty
                {
                    rows.append(tableCells(lines[index]))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
            } else {
                paragraph.append(trimmed)
                index += 1
            }
        }
        flushParagraph()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        guard line.count >= 3, let first = line.first, "-*_".contains(first) else { return false }
        return line.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> MarkdownBlock.ListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let body = line.dropFirst(indent)
        let depth = indent / 2
        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            return .init(depth: depth, marker: "•", text: String(body.dropFirst(2)))
        }
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty, body.dropFirst(digits.count).hasPrefix(". ") {
            return .init(depth: depth, marker: "\(digits).", text: String(body.dropFirst(digits.count + 2)))
        }
        return nil
    }

    private static func isTableDivider(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("-") && trimmed.contains("|")
            && trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func tableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// Renders agent output. Written by hand so the app has no third-party dependencies.
struct MarkdownView: View {
    @Environment(\.projectRoot) private var projectRoot
    let text: String

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { handleLink($0, projectRoot: projectRoot) })
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            InlineText(text)
                .font(.system(size: level == 1 ? 19 : level == 2 ? 16 : 14, weight: .semibold))
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let text):
            InlineText(text)
                .font(Theme.body)
                .lineSpacing(3)
        case .code(let language, let text):
            CodeBlock(language: language, text: text)
        case .list(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(item.marker)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: 12, alignment: .trailing)
                        InlineText(item.text)
                            .lineSpacing(3)
                    }
                    .font(Theme.body)
                    .padding(.leading, CGFloat(item.depth) * 18)
                }
            }
        case .quote(let text):
            InlineText(text)
                .font(Theme.body)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 2)
                }
        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows)
        case .rule:
            Divider().padding(.vertical, 2)
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: text)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(SyntaxHighlighter.highlight(text, language: language))
                    .font(Theme.code)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
            }
        }
        .surface(cornerRadius: 10)
    }
}

private struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        InlineText(cell).font(.system(size: 12.5, weight: .semibold))
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            InlineText(cell).font(.system(size: 12.5))
                        }
                    }
                }
            }
            .padding(10)
        }
        .surface(cornerRadius: 10)
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
