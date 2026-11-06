import CryptoKit
import Foundation

public struct CodeCheckpoint: Codable, Sendable, Identifiable {
    public struct File: Codable, Sendable, Equatable {
        public var digest: String
        public var mode: Int
    }
    public var id: UUID
    public var projectID: UUID
    public var sessionID: UUID
    public var date: Date
    public var title: String
    public var roots: [String]
    public var before: [String: File]
    public var after: [String: File]?
    public var skipped: [String]
    public var restoredAt: Date?
    public var changedPaths: [String] {
        guard let after else { return [] }
        return Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
    }
}

/// Disk snapshots independent of Git's index. Only files captured on both sides of a turn
/// can be restored; subsequent edits and symlinks are rejected before any write.
public actor Checkpoints {
    private let directory: URL
    private let manager = FileManager.default
    private var captures = 0
    public init(directory: URL) { self.directory = directory }

    public func list(projectID: UUID) throws -> [CodeCheckpoint] {
        guard manager.fileExists(atPath: directory.path) else { return [] }
        return try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(CodeCheckpoint.self, from: Data(contentsOf: $0)) }
            .filter { $0.projectID == projectID }.sorted { $0.date > $1.date }
    }

    public func begin(projectID: UUID, sessionID: UUID, title: String, roots: [URL]) async throws -> CodeCheckpoint {
        captures += 1
        defer { captures -= 1 }
        try manager.createDirectory(at: directory.appendingPathComponent("blobs"), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let paths = Array(Set(roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })).sorted()
        let (files, skipped) = try await snapshot(roots: paths)
        let record = CodeCheckpoint(id: UUID(), projectID: projectID, sessionID: sessionID, date: .now,
                                    title: String(title.prefix(140)), roots: paths, before: files, skipped: skipped)
        try save(record)
        for old in try list(projectID: projectID).dropFirst(12) where old.after != nil {
            try manager.removeItem(at: location(old.id))
        }
        try pruneBlobs()
        return record
    }

    public func finish(_ id: UUID) async throws -> CodeCheckpoint {
        captures += 1
        defer { captures -= 1 }
        var record = try read(id)
        guard record.after == nil else { return record }
        let (after, skipped) = try await snapshot(roots: record.roots)
        // A skipped path on either side is outside the restore boundary.
        record.skipped = Array(Set(record.skipped + skipped)).sorted()
        record.before = record.before.filter { !record.skipped.contains($0.key) }
        record.after = after.filter { !record.skipped.contains($0.key) }
        try save(record)
        try pruneBlobs()
        return record
    }

    public func restore(_ id: UUID) throws -> CodeCheckpoint {
        var record = try read(id)
        guard let after = record.after, record.restoredAt == nil else {
            throw AgentError.launchFailed("This checkpoint is still recording or has already been restored.")
        }
        // Validate every path and blob first; a conflict must not partially rewind the project.
        for path in record.changedPaths {
            let url = try validated(path, roots: record.roots)
            let current = try fingerprint(url)
            guard current == after[path] else {
                throw AgentError.launchFailed("Cannot rewind: \(url.lastPathComponent) changed after this turn. Keep or save those edits first.")
            }
            if let before = record.before[path] {
                let data = try Data(contentsOf: blob(before.digest))
                guard Self.digest(data) == before.digest else { throw AgentError.launchFailed("Checkpoint data is damaged; files were kept.") }
            }
        }
        for path in record.changedPaths {
            let url = try validated(path, roots: record.roots)
            if let before = record.before[path] {
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contentsOf: blob(before.digest)).write(to: url, options: .atomic)
                try manager.setAttributes([.posixPermissions: before.mode], ofItemAtPath: path)
            } else { try manager.removeItem(at: url) }
        }
        record.restoredAt = .now
        try save(record)
        return record
    }

    private func snapshot(roots: [String]) async throws -> ([String: CodeCheckpoint.File], [String]) {
        var files: [String: CodeCheckpoint.File] = [:], skipped: [String] = []
        var total = 0
        for path in roots {
            let root = URL(fileURLWithPath: path)
            guard manager.fileExists(atPath: path) else { throw AgentError.launchFailed("Checkpoint folder no longer exists: \(path)") }
            let git = try await Command.run(URL(fileURLWithPath: "/usr/bin/git"),
                ["-C", path, "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
                environment: ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }.merging(["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"]) { _, new in new }, timeout: 20)
            let names: [String]
            if git.succeeded { names = git.output.split(separator: "\0").map(String.init) }
            else { names = try await ProjectFiles(root: root).filePaths(limit: 100_001) }
            guard names.count <= 100_000 else { throw AgentError.launchFailed("Too many files to create a checkpoint.") }
            for name in Set(names).sorted() {
                try Task.checkCancellation()
                let url = root.appendingPathComponent(name).standardizedFileURL
                do {
                    _ = try validated(url.path, roots: [path])
                    guard manager.fileExists(atPath: url.path) else { continue }
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard values.isRegularFile == true, (values.fileSize ?? 0) <= 5_000_000,
                          total + (values.fileSize ?? 0) <= 100_000_000 else { skipped.append(url.path); continue }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    guard data.count <= 5_000_000, total + data.count <= 100_000_000 else { skipped.append(url.path); continue }
                    total += data.count
                    let hash = Self.digest(data)
                    if !manager.fileExists(atPath: blob(hash).path) { try data.write(to: blob(hash), options: .atomic) }
                    let mode = (try manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
                    files[url.path] = CodeCheckpoint.File(digest: hash, mode: mode)
                } catch is CancellationError { throw CancellationError() }
                catch { skipped.append(url.path) }
            }
        }
        return (files, skipped)
    }

    private func validated(_ path: String, roots: [String]) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard roots.contains(where: { url.path.hasPrefix($0 + "/") }),
              !url.pathComponents.contains(".git"), url.resolvingSymlinksInPath().path == url.path else {
            throw AgentError.launchFailed("Checkpoint path is outside its original folder or is a symbolic link.")
        }
        return url
    }
    private func fingerprint(_ url: URL) throws -> CodeCheckpoint.File? {
        guard manager.fileExists(atPath: url.path) else { return nil }
        let attr = try manager.attributesOfItem(atPath: url.path)
        guard attr[.type] as? FileAttributeType == .typeRegular else { throw AgentError.launchFailed("A checkpoint path is no longer a regular file.") }
        guard ((attr[.size] as? NSNumber)?.intValue ?? Int.max) <= 5_000_000 else { throw AgentError.launchFailed("A checkpoint file has grown beyond the restore limit.") }
        return CodeCheckpoint.File(digest: Self.digest(try Data(contentsOf: url)), mode: (attr[.posixPermissions] as? NSNumber)?.intValue ?? 0o644)
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func pruneBlobs() throws {
        guard captures == 1 else { return }
        var referenced = Set<String>()
        for url in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
            // Keep all blobs if any manifest is unreadable rather than deleting recovery data.
            let record = try JSONDecoder().decode(CodeCheckpoint.self, from: Data(contentsOf: url))
            referenced.formUnion(record.before.values.map(\.digest)); referenced.formUnion(record.after?.values.map(\.digest) ?? [])
        }
        for url in try manager.contentsOfDirectory(at: directory.appendingPathComponent("blobs"), includingPropertiesForKeys: nil) where !referenced.contains(url.lastPathComponent) {
            try manager.removeItem(at: url)
        }
    }
    private func blob(_ hash: String) -> URL { directory.appendingPathComponent("blobs/" + hash) }
    private func location(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    private func read(_ id: UUID) throws -> CodeCheckpoint { try JSONDecoder().decode(CodeCheckpoint.self, from: Data(contentsOf: location(id))) }
    private func save(_ record: CodeCheckpoint) throws { try JSONEncoder().encode(record).write(to: location(record.id), options: .atomic) }
}
