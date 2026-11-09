import AppKit
import Observation
@preconcurrency import WebKit

@MainActor @Observable
final class BrowserDownload: NSObject, Identifiable, WKDownloadDelegate {
    enum State { case choosingDestination, downloading, saving, completed, cancelled, failed }
    #if DEBUG
        static var destinationForTesting: URL?
    #endif
    let id = UUID()
    var name = "Download"
    private(set) var state: State = .choosingDestination
    private(set) var failureMessage: String?
    private(set) var receivedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    private(set) var fileURL: URL?
    var isRunning: Bool { state == .choosingDestination || state == .downloading || state == .saving }
    var canCancel: Bool { state == .choosingDestination || state == .downloading }
    var fractionCompleted: Double? {
        totalBytes > 0 ? min(1, max(0, Double(receivedBytes) / Double(totalBytes))) : nil
    }
    var canRetry: Bool {
        guard state == .failed || state == .cancelled, let request = originalRequest,
              ["http", "https"].contains(request.url?.scheme ?? ""), request.httpBody == nil,
              request.httpBodyStream == nil else { return false }
        return (request.httpMethod ?? "GET") == "GET"
    }
    var status: String {
        switch state {
        case .choosingDestination: "Choosing destination…"
        case .downloading:
            totalBytes > 0 ? "\(Self.bytes(receivedBytes)) of \(Self.bytes(totalBytes))" : "\(Self.bytes(receivedBytes)) downloaded"
        case .saving: "Saving…"
        case .completed: "Completed · \(Self.bytes(receivedBytes))"
        case .cancelled: "Cancelled"
        case .failed: failureMessage ?? "Download failed"
        }
    }
    @ObservationIgnored private var download: WKDownload?
    @ObservationIgnored private var originalRequest: URLRequest?
    @ObservationIgnored private var temporaryURL: URL?
    @ObservationIgnored private weak var workspace: BrowserWorkspace?
    @ObservationIgnored private var savePanel: NSSavePanel?
    @ObservationIgnored private var progressTask: Task<Void, Never>?

    init(_ download: WKDownload, workspace: BrowserWorkspace) {
        self.workspace = workspace
        originalRequest = download.originalRequest
        super.init()
        attach(download)
    }

    private func attach(_ download: WKDownload) {
        self.download = download
        download.delegate = self
    }

    private func observeProgress(_ download: WKDownload) {
        progressTask?.cancel()
        progressTask = Task { [weak self, weak download] in
            while !Task.isCancelled {
                guard let self, let download, self.isRunning, self.download === download else { return }
                self.receivedBytes = max(0, download.progress.completedUnitCount)
                if download.progress.totalUnitCount > 0 { self.totalBytes = download.progress.totalUnitCount }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        guard self.download === download, isRunning else { completionHandler(nil); return }
        name = suggestedFilename
        totalBytes = max(0, response.expectedContentLength)
        if let fileURL { acceptDestination(fileURL, completionHandler: completionHandler); return }
        #if DEBUG
            if let destination = Self.destinationForTesting {
                Self.destinationForTesting = nil
                acceptDestination(destination, completionHandler: completionHandler)
                return
            }
        #endif
        guard let window = download.webView?.window ?? workspace?.selectedPage?.webView.window else {
            cancel(); completionHandler(nil); return
        }
        let panel = NSSavePanel()
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        savePanel = panel
        panel.nameFieldStringValue = suggestedFilename
        panel.beginSheetModal(for: window) { [self] result in
            savePanel = nil
            guard self.download === download, isRunning else { completionHandler(nil); return }
            guard result == .OK, let destination = panel.url else { cancel(); completionHandler(nil); return }
            acceptDestination(destination, completionHandler: completionHandler)
        }
    }

    private func acceptDestination(_ destination: URL, completionHandler: (URL?) -> Void) {
        fileURL = destination
        // Keep WebKit's sandbox handoff in the app's temporary directory. The
        // app moves the completed file to the user-selected destination itself.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("marika-download-" + UUID().uuidString)
        temporaryURL = temporary
        state = .downloading
        completionHandler(temporary)
        if let download { observeProgress(download) }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard self.download === download, isRunning, let temporaryURL, let fileURL else { return }
        progressTask?.cancel()
        state = .saving
        Task {
            do {
                receivedBytes = try await Task.detached(priority: .utility) {
                    try Self.finishFile(temporaryURL, destination: fileURL)
                }.value
                self.temporaryURL = nil
                state = .completed
            } catch { failureMessage = error.localizedDescription; state = .failed; cleanup() }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard self.download === download, isRunning else { return }
        failureMessage = error.localizedDescription
        state = .failed
        progressTask?.cancel()
        cleanup()
    }

    func cancel() {
        guard canCancel else { return }
        state = .cancelled
        progressTask?.cancel()
        savePanel?.cancel(nil)
        let cancelled = download
        let cancelledFile = temporaryURL
        temporaryURL = nil
        cancelled?.cancel { _ in
            // A retry may already be writing to a different temporary file.
            if let cancelledFile { try? FileManager.default.removeItem(at: cancelledFile) }
        }
    }

    func retry() {
        guard canRetry, let request = originalRequest, let webView = workspace?.selectedPage?.webView else { return }
        // Retire the old delegate before starting another transfer.
        download?.delegate = nil
        download = nil
        cleanup()
        state = fileURL == nil ? .choosingDestination : .downloading
        failureMessage = nil
        receivedBytes = 0
        totalBytes = 0
        webView.startDownload(using: request) { [weak self] download in
            guard let self, self.isRunning else { download.cancel { _ in }; return }
            self.attach(download)
        }
    }

    private static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    private nonisolated static func finishFile(_ source: URL, destination: URL) throws -> Int64 {
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        let size = (try manager.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
        // Stage beside the destination so replacing it remains atomic across volumes.
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".marika-save-" + UUID().uuidString)
        defer { try? manager.removeItem(at: staged) }
        try manager.copyItem(at: source, to: staged)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staged)
        } else { try manager.moveItem(at: staged, to: destination) }
        try? manager.removeItem(at: source)
        return size
    }
    private func cleanup() {
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        temporaryURL = nil
    }
}
