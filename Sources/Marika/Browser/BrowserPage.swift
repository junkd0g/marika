import AppKit
import MarikaCore
import Observation
@preconcurrency import WebKit

@MainActor
@Observable
final class BrowserPage: NSObject, Identifiable, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let id = UUID()
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored weak var workspace: BrowserWorkspace?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    var url: URL? { didSet { workspace?.onStateChange?() } }
    var title = "New tab"
    var isLoading = false
    var progress = 0.0
    var canGoBack = false
    var canGoForward = false
    var navigationError: String?
    var isAnnotating = false

    init(workspace: BrowserWorkspace, dataStore: WKWebsiteDataStore) {
        self.workspace = workspace
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.applicationNameForUserAgent = "Marika/0.1"
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.addUserScript(WKUserScript(
            source: BrowserScripts.bootstrap, injectionTime: .atDocumentEnd, forMainFrameOnly: true,
            in: .world(name: BrowserScripts.world)))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = true
        configuration.userContentController.add(self, contentWorld: .world(name: BrowserScripts.world), name: "marikaElement")
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in MainActor.assumeIsolated {
                if let url = view.url { self?.url = url }
            } },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in MainActor.assumeIsolated { self?.title = view.title ?? "New tab" } },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in MainActor.assumeIsolated { self?.isLoading = view.isLoading } },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in MainActor.assumeIsolated { self?.progress = view.estimatedProgress } },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoBack = view.canGoBack } },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoForward = view.canGoForward } },
        ]
    }

    func load(_ url: URL) {
        navigationError = nil
        self.url = url
        isLoading = true
        isAnnotating = false
        if url.isFileURL, let root = workspace?.root { webView.loadFileURL(url, allowingReadAccessTo: root) }
        else { webView.load(URLRequest(url: url)) }
    }

    func evaluate(_ script: String) async throws -> JSONValue {
        let source = "JSON.stringify((() => { \(script) })())"
        let result: String = try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(source, in: nil, in: .world(name: BrowserScripts.world)) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value as? String ?? "null")
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
        return try JSONValue(parsing: Data(result.utf8))
    }

    func screenshot() async throws -> Data {
        guard webView.bounds.width > 0, webView.bounds.height > 0 else { throw BrowserError.message("Open the Browser tab before taking a screenshot.") }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 1200
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let error { continuation.resume(throwing: error) }
                else if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: BrowserError.message("The page couldn't be captured.")) }
            }
        }
        guard let tiff = image.tiffRepresentation, let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            throw BrowserError.message("The screenshot couldn't be encoded.")
        }
        return data
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let root = workspace?.root else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        do {
            _ = try BrowserAddress.validate(url, projectRoot: root)
            decisionHandler(.allow)
        } catch {
            workspace?.errorMessage = error.localizedDescription
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationError = nil
        isLoading = true
        isAnnotating = false
        if workspace?.selectedPageID == id { workspace?.clearFeedback() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        if workspace?.selectedPageID == id, let url = webView.url { workspace?.onNavigate?(url.absoluteString) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        navigationError = error.localizedDescription
        isLoading = false
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navigationError = "The page's browser process stopped. Reload to continue."
        isLoading = false
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, let workspace,
            (try? BrowserAddress.validate(url, projectRoot: workspace.root)) != nil {
            workspace.newPage(url: url)
        }
        return nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.name == "marikaElement",
            let body = try? JSONSerialization.data(withJSONObject: message.body), let selection = try? JSONValue(parsing: body)
        else { return }
        isAnnotating = false
        workspace?.annotation = selection
    }
}
