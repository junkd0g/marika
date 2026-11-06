import Foundation

public struct ProjectSearchMatch: Identifiable, Equatable, Sendable {
    public var path: String
    public var line: Int
    public var column: Int
    public var length: Int
    public var preview: String
    public var id: String { "\(path):\(line):\(column)" }
}

public enum ProjectSearch {
    public static func search(_ query: String, root: URL, caseSensitive: Bool = false, limit: Int = 500, regularExpression: Bool = false, files provided: (any WorkspaceFiles)? = nil) async throws -> [ProjectSearchMatch] {
        guard !query.isEmpty, limit > 0 else { return [] }
        let files: any WorkspaceFiles = provided ?? ProjectFiles(root: root)
        let paths = try await files.filePaths(limit: 20_000)
        let expression = try NSRegularExpression(pattern: regularExpression ? query : NSRegularExpression.escapedPattern(for: query), options: caseSensitive ? [] : [.caseInsensitive])
        var matches: [ProjectSearchMatch] = []
        for path in paths {
            try Task.checkCancellation()
            guard let snapshot = try? await files.read(path) else { continue }
            for (index, line) in snapshot.text.components(separatedBy: "\n").enumerated() {
                try Task.checkCancellation()
                let text = line as NSString
                for match in expression.matches(in: line, range: NSRange(location: 0, length: text.length)) {
                    let range = match.range
                    let start = max(0, range.location - 90)
                    let preview = text.substring(with: NSRange(location: start, length: min(240, text.length - start)))
                    matches.append(ProjectSearchMatch(path: path, line: index + 1, column: range.location + 1,
                                                      length: range.length, preview: preview))
                    if matches.count >= limit { return matches }
                }
            }
        }
        return matches
    }
}

public struct ProjectReplacement: Sendable {
    public var snapshot: TextFileSnapshot
    public var updated: String
}
extension ProjectSearch {
    public static func replacements(_ query: String, replacement: String, caseSensitive: Bool, regularExpression: Bool, files: any WorkspaceFiles) async throws -> [ProjectReplacement] {
        guard !query.isEmpty else { return [] }
        let expression = try NSRegularExpression(pattern: regularExpression ? query : NSRegularExpression.escapedPattern(for: query), options: caseSensitive ? [] : [.caseInsensitive])
        var edits: [ProjectReplacement] = []
        for path in try await files.filePaths(limit: 20_000) {
            try Task.checkCancellation()
            guard let snapshot = try? await files.read(path) else { continue }
            let updated = expression.stringByReplacingMatches(in: snapshot.text, range: NSRange(location: 0, length: (snapshot.text as NSString).length), withTemplate: regularExpression ? replacement : NSRegularExpression.escapedTemplate(for: replacement))
            if updated != snapshot.text { edits.append(ProjectReplacement(snapshot: snapshot, updated: updated)) }
            guard edits.count <= 500 else { throw AgentError.launchFailed("More than 500 files match. Narrow the replacement.") }
        }
        return edits
    }
}
