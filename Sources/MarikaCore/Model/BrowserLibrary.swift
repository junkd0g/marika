import Foundation

public struct BrowserLocation: Codable, Hashable, Identifiable, Sendable {
    public var url: URL
    public var title: String
    public var visitedAt: Date
    public var id: String { url.absoluteString }

    public init(url: URL, title: String, visitedAt: Date = Date()) {
        self.url = url
        self.title = title.isEmpty ? (url.host ?? url.lastPathComponent) : title
        self.visitedAt = visitedAt
    }
}

/// Project-scoped history and bookmarks. Recording a visit moves it to the front.
public struct BrowserLibrary: Codable, Hashable, Sendable {
    public private(set) var history: [BrowserLocation] = []
    public private(set) var bookmarks: [BrowserLocation] = []
    public init() {}

    public mutating func record(_ location: BrowserLocation) {
        history.removeAll { $0.url == location.url }
        history.insert(location, at: 0)
        history = Array(history.prefix(100))
    }

    public func isBookmarked(_ url: URL) -> Bool { bookmarks.contains { $0.url == url } }

    public mutating func toggleBookmark(_ location: BrowserLocation) {
        if isBookmarked(location.url) { bookmarks.removeAll { $0.url == location.url } }
        else { bookmarks.insert(location, at: 0) }
    }

    public mutating func clearHistory() { history.removeAll() }

    public mutating func removeHistory(_ url: URL) { history.removeAll { $0.url == url } }
    public mutating func removeBookmark(_ url: URL) { bookmarks.removeAll { $0.url == url } }

    public mutating func editBookmark(_ original: URL, title: String, url: URL) {
        guard let index = bookmarks.firstIndex(where: { $0.url == original }) else { return }
        let date = bookmarks[index].visitedAt
        bookmarks.removeAll { $0.url == original || $0.url == url }
        bookmarks.insert(BrowserLocation(url: url, title: title, visitedAt: date), at: min(index, bookmarks.count))
    }

    public func search(_ query: String, bookmarksOnly: Bool = false) -> [BrowserLocation] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (bookmarksOnly ? bookmarks : history).filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.url.absoluteString.localizedCaseInsensitiveContains(query)
        }
    }

    public mutating func updateTitle(for url: URL, to title: String) {
        guard !title.isEmpty, let index = history.firstIndex(where: { $0.url == url }) else { return }
        history[index].title = title
    }

    public func suggestions(for query: String, limit: Int = 6) -> [BrowserLocation] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen: Set<URL> = []
        return Array((bookmarks + history).filter {
            (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
             || $0.url.absoluteString.localizedCaseInsensitiveContains(query)) && seen.insert($0.url).inserted
        }.prefix(max(0, limit)))
    }
}
