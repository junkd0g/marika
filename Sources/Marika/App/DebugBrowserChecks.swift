#if DEBUG
import AppKit
import MarikaCore
import WebKit

@MainActor enum BrowserPolishChecks {
    static func run(_ browser: BrowserWorkspace) async throws {
        guard let page = browser.selectedPage, let url = page.url else { throw failure("No loaded page") }
        try await wait { page.favicon != nil }
        let destination = browser.root.appendingPathComponent("retry-result.bin")
        try Data("Keep existing file".utf8).write(to: destination)
        BrowserDownload.destinationForTesting = destination
        page.webView.startDownload(using: URLRequest(url: url.deletingLastPathComponent().appendingPathComponent("flaky.bin"))) {
            browser.startDownload($0)
        }
        try await wait { browser.downloads.first?.state == .failed }
        guard let download = browser.downloads.first, download.canRetry,
              try String(contentsOf: destination, encoding: .utf8) == "Keep existing file" else { throw failure("Failed transfer damaged its destination") }
        let id = download.id
        download.retry()
        try await wait { download.state == .completed }
        guard download.id == id, try String(contentsOf: destination, encoding: .utf8) == "Retried download fixture" else { throw failure("Retry did not save the expected content") }

        let slowFile = browser.root.appendingPathComponent("slow-result.bin")
        BrowserDownload.destinationForTesting = slowFile
        page.webView.startDownload(using: URLRequest(url: url.deletingLastPathComponent().appendingPathComponent("slow.bin"))) { browser.startDownload($0) }
        try await wait { browser.downloads.first?.id != id && browser.downloads.first?.receivedBytes ?? 0 > 0 }
        guard let slow = browser.downloads.first, slow.totalBytes > 0 else { throw failure("No byte progress") }
        slow.cancel()
        guard slow.state == .cancelled, slow.canRetry, !FileManager.default.fileExists(atPath: slowFile.path) else { throw failure("Cancellation left a completed file") }
        try await Task.sleep(for: .milliseconds(300))
        slow.retry()
        try await wait { slow.state == .completed }
        guard slow.receivedBytes == 1_048_576 else { throw failure("Retried file has an unexpected size") }

        let history = browser.library.history
        let bookmarks = browser.library.bookmarks
        let isolated = BrowserWorkspace(root: browser.root)
        defer { isolated.stop() }
        isolated.navigate(url.absoluteString)
        try await wait { isolated.selectedPage?.isLoading == false }
        guard try await isolated.selectedPage?.evaluate("return document.cookie.includes('marika_test=retained');") == .bool(false) else { throw failure("Project sessions share cookies") }
        await browser.refreshWebsiteData()
        guard !browser.websiteRecords.isEmpty else { throw failure("Website data was not listed") }
        await browser.removeWebsiteData(browser.websiteRecords)
        page.reload()
        try await wait { !page.isLoading }
        try await Task.sleep(for: .milliseconds(300))
        guard try await page.evaluate("return document.cookie.includes('marika_test=retained') || localStorage.getItem('marika_test') === 'retained';") == .bool(false),
              browser.library.bookmarks == bookmarks,
              Set(browser.library.history.map(\.url)) == Set(history.map(\.url)) else { throw failure("Website data removal failed or changed the library") }
    }

    private static func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        if !predicate() { throw failure("Browser check timed out") }
    }

    private static func failure(_ message: String) -> NSError { NSError(domain: "BrowserPolishChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
#endif
