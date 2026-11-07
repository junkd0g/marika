import Foundation

/// The block structure of a Markdown message.
public enum MarkdownBlock: Equatable, Sendable {
    public struct ListItem: Equatable, Sendable {
        public var depth: Int
        public var marker: String
        public var text: String
        public var checked: Bool?
    }

    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String, text: String)
    case list([ListItem])
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule
    case image(alt: String, source: String)
}

public enum MarkdownParser {
    public static func isMarkdown(_ path: String) -> Bool {
        ["md", "markdown", "mdown", "mkd"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    public static func anchor(_ heading: String) -> String {
        heading.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
            .replacingOccurrences(of: " ", with: "-")
    }

    public static func headingAnchors(in blocks: [MarkdownBlock]) -> [Int: String] {
        var counts: [String: Int] = [:], anchors: [Int: String] = [:]
        for (index, block) in blocks.enumerated() {
            guard case .heading(_, let text) = block else { continue }
            let base = anchor(text)
            let count = counts[base, default: 0]
            anchors[index] = count == 0 ? base : base + "-\(count)"
            counts[base] = count + 1
        }
        return anchors
    }

    public static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
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
                let fence = String(trimmed.prefix { $0 == trimmed.first })
                let language = trimmed.dropFirst(fence.count).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                var body: [String] = []
                index += 1
                while index < lines.count, !isClosingFence(lines[index], fence: fence) {
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
            } else if index + 1 < lines.count, !trimmed.isEmpty, let level = setextLevel(lines[index + 1]) {
                flushParagraph()
                blocks.append(.heading(level: level, text: trimmed))
                index += 2
            } else if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
            } else if let image = image(trimmed) {
                flushParagraph()
                blocks.append(image)
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
        var text = line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces)
        if let range = text.range(of: #"\s+#+\s*$"#, options: .regularExpression) { text.removeSubrange(range) }
        return .heading(level: hashes, text: text)
    }

    private static func isClosingFence(_ line: String, fence: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= fence.count && trimmed.allSatisfy { $0 == fence.first }
    }

    private static func setextLevel(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private static func image(_ line: String) -> MarkdownBlock? {
        guard let expression = try? NSRegularExpression(pattern: #"^!\[([^\]]*)\]\((?:<([^>]+)>|([^\s]+?))(?:\s+\"[^\"]*\")?\)$"#),
              let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        let source = line as NSString
        let destination = match.range(at: 2).location == NSNotFound ? match.range(at: 3) : match.range(at: 2)
        return .image(alt: source.substring(with: match.range(at: 1)), source: source.substring(with: destination))
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
            var text = String(body.dropFirst(2))
            var checked: Bool?
            if text.hasPrefix("[ ] ") || text.lowercased().hasPrefix("[x] ") {
                checked = text.lowercased().hasPrefix("[x]")
                text = String(text.dropFirst(4))
            }
            return .init(depth: depth, marker: "•", text: text, checked: checked)
        }
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty, body.dropFirst(digits.count).hasPrefix(". ") {
            return .init(depth: depth, marker: "\(digits).", text: String(body.dropFirst(digits.count + 2)), checked: nil)
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
        var cells: [String] = [], current = "", escaped = false, inCode = false
        for character in trimmed {
            if escaped {
                if character != "|" { current.append("\\") }
                current.append(character); escaped = false; continue
            }
            if character == "\\" { escaped = true; continue }
            if character == "`" { inCode.toggle() }
            if character == "|" && !inCode { cells.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            else { current.append(character) }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }
}

/// Markdown resources resolve relative to their document, and stay within the project.
public enum MarkdownResource {
    public static func localURL(_ reference: String, document: URL, root: URL) -> URL? {
        guard let components = URLComponents(string: reference), components.scheme == nil || components.scheme == "file",
              components.host == nil || components.host == "" || components.host == "localhost" else { return nil }
        var clean = components
        clean.fragment = nil; clean.query = nil
        let reference = clean.string ?? ""
        guard let absolute = reference.isEmpty ? document : URL(string: reference, relativeTo: document)?.absoluteURL,
              absolute.isFileURL else { return nil }
        // Resolve existing parents too: Foundation leaves a missing leaf under a symlink
        // unresolved, which otherwise lets a future image bypass the project boundary.
        var parent = absolute.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: parent.path), parent.path != "/" {
            missing.append(parent.lastPathComponent)
            parent.deleteLastPathComponent()
        }
        var resolved = parent.resolvingSymlinksInPath()
        for component in missing.reversed() { resolved.appendPathComponent(component) }
        let boundary = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.path == boundary || resolved.path.hasPrefix(boundary + "/") else { return nil }
        return resolved
    }
}
