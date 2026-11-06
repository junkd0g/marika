import Foundation

public struct DiffLine: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case context
        case addition
        case deletion
        case hunk
    }

    public var kind: Kind
    public var oldNumber: Int?
    public var newNumber: Int?
    public var text: String

    public init(kind: Kind, oldNumber: Int? = nil, newNumber: Int? = nil, text: String) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
    }
}

public struct DiffFile: Codable, Equatable, Sendable, Identifiable {
    /// What happens to the file. Nil when the agent didn't say.
    public enum Change: String, Codable, Sendable {
        case added
        case deleted
        case modified
        case moved
    }

    public var path: String
    /// Where the file ended up, when the change also moved it.
    public var movedTo: String?
    public var lines: [DiffLine]
    public var isBinary: Bool
    public var change: Change?
    /// True when this writes over a file that's already there, whatever the diff looks like.
    public var replacesExisting: Bool?

    public var id: String { path }
    public var additions: Int { lines.count { $0.kind == .addition } }
    public var deletions: Int { lines.count { $0.kind == .deletion } }

    public init(
        path: String, movedTo: String? = nil, lines: [DiffLine] = [], isBinary: Bool = false, change: Change? = nil,
        replacesExisting: Bool? = nil
    ) {
        self.path = path
        self.movedTo = movedTo
        self.lines = lines
        self.isBinary = isBinary
        self.change = change
        self.replacesExisting = replacesExisting
    }
}

extension DiffFile {
    /// Builds a diff from the hunks an agent reports after an edit.
    public init(path: String, structuredPatch: [JSONValue]) {
        var lines: [DiffLine] = []
        for hunk in structuredPatch {
            var old = hunk["oldStart"]?.int ?? 1
            var new = hunk["newStart"]?.int ?? 1
            if !lines.isEmpty {
                lines.append(DiffLine(kind: .hunk, text: "⋯"))
            }
            for raw in hunk["lines"]?.array ?? [] {
                guard let text = raw.string else { continue }
                Self.append(text, old: &old, new: &new, to: &lines)
            }
        }
        self.init(path: path, lines: lines)
    }

    /// Every line of a new file, shown as an addition.
    public init(path: String, newContent: String) {
        let lines = Self.splitLines(newContent).enumerated().map { index, text in
            DiffLine(kind: .addition, newNumber: index + 1, text: text)
        }
        self.init(path: path, lines: lines)
    }

    /// Every line of a removed file, shown as a deletion.
    public init(path: String, removedContent: String) {
        let lines = Self.splitLines(removedContent).enumerated().map { index, text in
            DiffLine(kind: .deletion, oldNumber: index + 1, text: text)
        }
        self.init(path: path, lines: lines)
    }

    /// A preview of an edit that has not happened yet, so line numbers are unknown. Agents
    /// include surrounding lines to anchor an edit, so lines shared by both ends are context.
    public init(path: String, replacing oldText: String, with newText: String) {
        let old = Self.splitLines(oldText)
        let new = Self.splitLines(newText)
        let prefix = zip(old, new).prefix { $0 == $1 }.count
        let suffix = zip(old.dropFirst(prefix).reversed(), new.dropFirst(prefix).reversed()).prefix { $0 == $1 }.count

        var lines = old.prefix(prefix).map { DiffLine(kind: .context, text: $0) }
        lines += old[prefix..<(old.count - suffix)].map { DiffLine(kind: .deletion, text: $0) }
        lines += new[prefix..<(new.count - suffix)].map { DiffLine(kind: .addition, text: $0) }
        lines += old.suffix(suffix).map { DiffLine(kind: .context, text: $0) }
        self.init(path: path, lines: lines)
    }

    private static func splitLines(_ text: String) -> [String] {
        var lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map { withoutCarriageReturn(String($0)) }
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Swift treats `\r\n` as one Character, so CRLF text has to be split on scalars, and the
    /// stray `\r` would otherwise draw as an empty line under every row.
    fileprivate static func withoutCarriageReturn(_ line: String) -> String {
        line.unicodeScalars.last == "\r" ? String(String.UnicodeScalarView(line.unicodeScalars.dropLast())) : line
    }

    fileprivate static func append(_ line: String, old: inout Int, new: inout Int, to lines: inout [DiffLine]) {
        let raw = withoutCarriageReturn(line)
        switch raw.first {
        case "+":
            lines.append(DiffLine(kind: .addition, newNumber: new, text: String(raw.dropFirst())))
            new += 1
        case "-":
            lines.append(DiffLine(kind: .deletion, oldNumber: old, text: String(raw.dropFirst())))
            old += 1
        case "\\":
            break  // "\ No newline at end of file"
        default:
            lines.append(DiffLine(kind: .context, oldNumber: old, newNumber: new, text: String(raw.dropFirst())))
            old += 1
            new += 1
        }
    }
}

/// Parses unified diffs, as printed by `git diff` or reported by an agent.
public enum DiffParser {
    public static func parse(_ text: String, defaultPath: String = "") -> [DiffFile] {
        var files: [DiffFile] = []
        var current: DiffFile?
        var old = 0
        var new = 0
        var inHunk = false

        func flush() {
            if let finished = current { files.append(finished) }
            current = nil
            inHunk = false
        }

        for rawLine in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("diff --git ") {
                flush()
                current = DiffFile(path: path(fromHeader: line))
            } else if !inHunk || current == nil, line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                let candidate = stripPrefix(String(line.dropFirst(4)))
                if candidate != "/dev/null" {
                    if current == nil { current = DiffFile(path: candidate) }
                    current?.path = candidate
                }
            } else if line.hasPrefix("Binary files ") {
                if current == nil { current = DiffFile(path: defaultPath) }
                current?.isBinary = true
            } else if line.hasPrefix("@@"), let range = parseHunkHeader(line) {
                if current == nil { current = DiffFile(path: defaultPath) }
                if current?.lines.isEmpty == false {
                    current?.lines.append(DiffLine(kind: .hunk, text: "⋯"))
                }
                old = range.old
                new = range.new
                inHunk = true
            } else if inHunk, var file = current {
                // `split` leaves a trailing empty element that is not a diff line.
                if line.isEmpty { continue }
                DiffFile.append(line, old: &old, new: &new, to: &file.lines)
                current = file
            }
        }
        flush()
        return files
    }

    private static func parseHunkHeader(_ line: String) -> (old: Int, new: Int)? {
        // @@ -12,7 +12,9 @@ optional context
        let parts = line.split(separator: " ")
        guard parts.count >= 3,
            let old = Int(parts[1].dropFirst().split(separator: ",").first ?? ""),
            let new = Int(parts[2].dropFirst().split(separator: ",").first ?? "")
        else { return nil }
        return (old, new)
    }

    private static func path(fromHeader line: String) -> String {
        // diff --git a/path b/path. Use the b/ side so renames show the new name.
        if let range = line.range(of: " b/", options: .backwards) {
            return String(line[range.upperBound...])
        }
        return String(line.dropFirst("diff --git ".count))
    }

    private static func stripPrefix(_ path: String) -> String {
        let trimmed = path.split(separator: "\t").first.map(String.init) ?? path
        if trimmed.hasPrefix("a/") || trimmed.hasPrefix("b/") { return String(trimmed.dropFirst(2)) }
        return trimmed
    }
}
