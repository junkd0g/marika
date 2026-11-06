import Foundation

public struct LanguageLocation: Sendable, Equatable {
    public var uri: String
    public var line: Int
    public var column: Int
    public var length: Int
}

public enum SourceNavigation {
    public static func locations(_ response: JSONValue) -> [LanguageLocation] {
        var seen = Set<String>()
        return (response.array ?? (response.isNull ? [] : [response])).compactMap { value in
            guard let uri = value["uri"]?.string ?? value["targetUri"]?.string,
                  let range = value["targetSelectionRange"] ?? value["range"] ?? value["targetRange"],
                  let line = range["start"]?["line"]?.int, line >= 0,
                  let column = range["start"]?["character"]?.int, column >= 0,
                  seen.insert("\(uri):\(line):\(column)").inserted else { return nil }
            let length = range["end"]?["line"]?.int == line ? max(0, (range["end"]?["character"]?.int ?? column) - column) : 0
            return LanguageLocation(uri: uri, line: line + 1, column: column + 1, length: length)
        }
    }
}

public struct TerminalFileLink: Sendable, Equatable {
    public var path: String
    public var line: Int
    public var column: Int
    public var range: NSRange

    /// Compiler locations, Python traceback frames, and JavaScript stack locations.
    public static func find(in text: String) -> [Self] {
        let patterns = [
            #"(?:File )\"([^\"\r\n]+)\", line ([0-9]+)"#,
            #"((?:/|\./|\.\./)?[^\s\"'()<>|]+\.[A-Za-z0-9_+-]+):([0-9]+)(?::([0-9]+))?"#,
            #"((?:/|\./|\.\./)?[^\s\"'()<>|]+\.[A-Za-z0-9_+-]+)\(([0-9]+)(?:,([0-9]+))?\)"#
        ]
        var result: [Self] = []
        let source = text as NSString
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                let path = source.substring(with: match.range(at: 1))
                guard !path.contains("://"), let line = Int(source.substring(with: match.range(at: 2))), line > 0,
                      !result.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) else { continue }
                let column = match.numberOfRanges > 3 && match.range(at: 3).location != NSNotFound ? Int(source.substring(with: match.range(at: 3))) ?? 1 : 1
                result.append(Self(path: path, line: line, column: max(1, column), range: match.range))
            }
        }
        return result.sorted { $0.range.location < $1.range.location }
    }

    public func resolved(relativeTo directory: URL, allowedRoots: [URL]) -> (root: URL, path: String)? {
        let target = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)).standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        for root in allowedRoots {
            let base = root.standardizedFileURL.resolvingSymlinksInPath()
            if target.path.hasPrefix(base.path + "/") { return (root, String(target.path.dropFirst(base.path.count + 1))) }
        }
        return nil
    }
}
