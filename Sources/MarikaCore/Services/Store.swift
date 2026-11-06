import Foundation

public struct StoreError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// Atomic local storage with a last known good backup. Corrupt data is never replaced silently.
public actor Store {
    public nonisolated let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var protectedFiles: Set<URL> = []
    private var recoveryNotices: [String] = []

    public init(root: URL = Store.defaultRoot) {
        self.root = root
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Marika", isDirectory: true)
    }

    public nonisolated var attachmentsDirectory: URL { root.appendingPathComponent("attachments", isDirectory: true) }
    public nonisolated var worktreesDirectory: URL { root.appendingPathComponent("worktrees", isDirectory: true) }
    private var workspaceURL: URL { root.appendingPathComponent("workspace.json") }
    private var transcriptsDirectory: URL { root.appendingPathComponent("transcripts", isDirectory: true) }

    private func transcriptURL(_ id: UUID) -> URL { transcriptsDirectory.appendingPathComponent("\(id.uuidString).json") }
    private func backupURL(_ url: URL) -> URL { url.appendingPathExtension("bak") }

    public func takeRecoveryNotices() -> [String] {
        defer { recoveryNotices.removeAll() }
        return recoveryNotices
    }

    /// Revalidate repaired files (or recover their backups) without replacing in-memory edits.
    public func retryFailedSaves() throws {
        for url in protectedFiles {
            if url == workspaceURL { let _: Workspace = try read(url, default: Workspace()) }
            else { let _: [TranscriptItem] = try read(url, default: []) }
        }
    }

    public func loadWorkspace() throws -> Workspace { try read(workspaceURL, default: Workspace()) }
    public func save(_ workspace: Workspace) throws { try write(workspace, to: workspaceURL) }
    public func loadTranscript(_ id: UUID) throws -> [TranscriptItem] { try read(transcriptURL(id), default: []) }
    public func saveTranscript(_ items: [TranscriptItem], for id: UUID) throws { try write(items, to: transcriptURL(id)) }

    public func deleteTranscript(_ id: UUID) {
        let url = transcriptURL(id)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: backupURL(url))
        protectedFiles.remove(url)
    }

    private func read<Value: Codable>(_ url: URL, default fallback: Value) throws -> Value {
        let backup = backupURL(url)
        let manager = FileManager.default
        do {
            let value = try decoder.decode(Value.self, from: Data(contentsOf: url))
            protectedFiles.remove(url)
            return value
        } catch {
            let originalError = error
            do {
                let data = try Data(contentsOf: backup)
                let value = try decoder.decode(Value.self, from: data)
                // Keep the damaged original for manual inspection or recovery.
                if !isMissing(originalError) {
                    let damaged = url.deletingPathExtension().appendingPathExtension("corrupt-\(UUID().uuidString).json")
                    try manager.copyItem(at: url, to: damaged)
                }
                try data.write(to: url, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                protectedFiles.remove(url)
                recoveryNotices.append("Recovered \(url.lastPathComponent) from its last good backup. The damaged original was kept in Saved Data.")
                return value
            } catch {
                if isMissing(originalError), isMissing(error) {
                    protectedFiles.remove(url)
                    return fallback
                }
                protectedFiles.insert(url)
                throw StoreError(message: "Couldn't load \(url.lastPathComponent) or recover its backup. Your saved files have been kept. Open Saved Data to restore a valid copy, then try again.\n\(error.localizedDescription)")
            }
        }
    }

    private func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
    }

    private func write<Value: Codable>(_ value: Value, to url: URL) throws {
        guard !protectedFiles.contains(url) else {
            throw StoreError(message: "Saving \(url.lastPathComponent) is paused to protect unreadable data. Restore it in Saved Data and reload it before saving.")
        }
        do {
            let data = try encoder.encode(value)
            let manager = FileManager.default
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            var backup = data
            do {
                backup = try Data(contentsOf: url)
                // Never rotate corrupt data over the last valid backup, even if load was skipped.
                do { _ = try decoder.decode(Value.self, from: backup) }
                catch {
                    protectedFiles.insert(url)
                    throw StoreError(message: "\(url.lastPathComponent) changed or became unreadable. Reload it before saving; its backup has been kept.")
                }
            } catch {
                if !isMissing(error) { throw error }
            }
            try backup.write(to: backupURL(url), options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL(url).path)
            try data.write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw StoreError(message: "Couldn't save \(url.lastPathComponent). Your changes are still in memory.\n\(error.localizedDescription)")
        }
    }
}
