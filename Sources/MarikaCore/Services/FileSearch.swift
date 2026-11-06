import Foundation

public enum FileSearch {
    /// Prefer filenames, then paths, while allowing abbreviations such as "cws".
    public static func matches(_ paths: [String], query: String, limit: Int = 100) -> [String] {
        guard limit > 0 else { return [] }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return Array(paths.prefix(limit)) }
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return paths.compactMap { path -> (String, Int)? in
            let lower = path.lowercased()
            let name = (lower as NSString).lastPathComponent
            var score = 0
            for term in terms {
                if name == term { score += 0 }
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
            return (path, score)
        }
        .sorted { $0.1 == $1.1 ? $0.0.localizedStandardCompare($1.0) == .orderedAscending : $0.1 < $1.1 }
        .prefix(limit).map(\.0)
    }
}
