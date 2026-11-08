import Foundation

public enum FileSearch {
    /// Prefer exact filenames and stems, then paths and abbreviations such as "cws".
    /// Break equally relevant matches in favor of source and shallower paths.
    public static func matches(_ paths: [String], query: String, limit: Int = 100) -> [String] {
        guard limit > 0 else { return [] }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let outputFolders: Set<String> = ["build", "dist", "out", "target", "coverage", ".next", ".cache", "generated", "__generated__"]
        return paths.compactMap { path -> (path: String, score: Int, output: Bool, depth: Int)? in
            let lower = path.lowercased()
            let name = (lower as NSString).lastPathComponent
            let stem = (name as NSString).deletingPathExtension
            let folders = lower.split(separator: "/").dropLast()
            var score = 0
            for term in terms {
                if lower == term || name == term { score += 0 }
                else if stem == term { score += 5 }
                else if name.hasPrefix(term) { score += 10 }
                else if name.contains(term) { score += 25 }
                else if lower.contains(term) { score += 50 }
                else {
                    var remaining = term.makeIterator()
                    var next = remaining.next()
                    for character in lower where next != nil {
                        if character == next { next = remaining.next() }
                    }
                    guard next == nil else { return nil }
                    score += 100 + lower.count
                }
            }
            let output = folders.contains { folder in
                // An explicit folder query should still find its contents directly.
                outputFolders.contains(String(folder)) && !terms.contains { $0.split(separator: "/").contains(folder) }
            }
            return (path, score, output, folders.count)
        }
        .sorted {
            if $0.score != $1.score { return $0.score < $1.score }
            if $0.output != $1.output { return !$0.output }
            if $0.depth != $1.depth { return $0.depth < $1.depth }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        .prefix(limit).map(\.path)
    }
}
