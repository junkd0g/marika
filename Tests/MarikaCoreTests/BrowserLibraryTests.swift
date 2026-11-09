import Foundation
import Testing
@testable import MarikaCore

struct BrowserLibraryTests {
    @Test func libraryManagementPreservesVisitsAndDeduplicatesEditedBookmarks() {
        var library = BrowserLibrary()
        let first = BrowserLocation(url: URL(string: "https://example.com/a")!, title: "First")
        let second = BrowserLocation(url: URL(string: "https://example.com/b")!, title: "Second")
        library.record(first); library.record(second)
        library.toggleBookmark(first); library.toggleBookmark(second)
        library.editBookmark(first.url, title: "Renamed", url: second.url)
        #expect(library.bookmarks.count == 1)
        #expect(library.search("RENAMED", bookmarksOnly: true).first?.url == second.url)
        #expect(library.bookmarks.first?.visitedAt == first.visitedAt)
        #expect(library.search("/a").first == first)
        library.removeBookmark(second.url)
        library.removeHistory(first.url)
        #expect(library.bookmarks.isEmpty)
        #expect(library.history == [second])
    }
    @Test func searchInputAndExplicitURLsStayDistinct() throws {
        let root = URL(fileURLWithPath: "/tmp/project")
        let search = try BrowserAddress.resolveOmnibox("  swift webkit find  ", projectRoot: root)
        #expect(search.host == "duckduckgo.com")
        #expect(URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "swift webkit find")
        #expect(try BrowserAddress.resolveOmnibox("browser", projectRoot: root).host == "duckduckgo.com")
        #expect(try BrowserAddress.resolveOmnibox("example.com/docs?q=hello%20world", projectRoot: root).host == "example.com")
        #expect(try BrowserAddress.resolveOmnibox("localhost:5173/test", projectRoot: root).scheme == "http")
        #expect(try BrowserAddress.resolveOmnibox("example.com:8443/test", projectRoot: root).port == 8443)
        #expect(try BrowserAddress.resolve("LOCALHOST:3000", projectRoot: root).scheme == "http")
        #expect(try BrowserAddress.resolve("[::1]", projectRoot: root).scheme == "http")
        #expect(try BrowserAddress.resolve("example.com/path:part?q=a:b", projectRoot: root).host == "example.com")
        for input in ["javascript:alert(1)", "data:text/html,hello", "mailto:a@example.com", "https://user:pass@example.com", ""] {
            #expect(throws: (any Error).self) { try BrowserAddress.resolveOmnibox(input, projectRoot: root) }
        }
    }

    @Test func historyDeduplicatesAndKeepsOnlyTheLastHundredPages() throws {
        var library = BrowserLibrary()
        for index in 0..<120 {
            library.record(BrowserLocation(url: URL(string: "https://example.com/\(index)")!, title: "Page \(index)"))
        }
        #expect(library.history.count == 100)
        #expect(library.history.first?.title == "Page 119")
        let revisited = library.history[40]
        library.record(BrowserLocation(url: revisited.url, title: "Updated title"))
        #expect(library.history.count == 100)
        #expect(library.history.first?.url == revisited.url)
        #expect(library.history.first?.title == "Updated title")
        #expect(library.history.filter { $0.url == revisited.url }.count == 1)
        let recorded = library.history[1]
        library.updateTitle(for: recorded.url, to: "Late document title")
        #expect(library.history[1].title == "Late document title")
        #expect(library.history[1].visitedAt == recorded.visitedAt)
        #expect(library.history.first?.title == "Updated title")
    }

    @Test func bookmarksSurviveClearingHistoryAndSuggestionsAreUnique() {
        var library = BrowserLibrary()
        let location = BrowserLocation(url: URL(string: "https://example.com/docs")!, title: "Reference")
        library.record(location)
        library.toggleBookmark(location)
        #expect(library.isBookmarked(location.url))
        #expect(library.suggestions(for: "EXAMPLE").count == 1)
        #expect(library.suggestions(for: "reference").first == location)
        #expect(library.suggestions(for: "missing").isEmpty)
        #expect(library.suggestions(for: "", limit: 0).isEmpty)
        library.clearHistory()
        #expect(library.history.isEmpty)
        #expect(library.bookmarks == [location])
        library.toggleBookmark(location)
        #expect(library.bookmarks.isEmpty)
    }

    @Test func libraryRoundTripsAndOldLayoutsStillLoad() throws {
        var layout = ProjectLayout()
        let location = BrowserLocation(url: URL(string: "https://example.com")!, title: "Example")
        layout.browserLibrary.record(location)
        layout.browserLibrary.toggleBookmark(location)
        #expect(try JSONDecoder().decode(ProjectLayout.self, from: JSONEncoder().encode(layout)) == layout)
        let old = try JSONDecoder().decode(ProjectLayout.self, from: Data("{\"browserURLs\":[\"https://example.com\"]}".utf8))
        #expect(old.browserLibrary.history.isEmpty)
        #expect(old.browserURLs.count == 1)
    }
}
