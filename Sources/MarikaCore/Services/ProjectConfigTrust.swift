import CryptoKit
import Darwin
import Foundation

/// Fingerprints the configuration Claude can load without running Git or project code.
public enum ProjectConfigTrust {
    public static func snapshot(from folder: URL) throws -> [String: String] {
        let manager = FileManager.default
        let folder = folder.standardizedFileURL.resolvingSymlinksInPath()
        var ancestors = [folder]
        while let last = ancestors.last, last.path != "/" { ancestors.append(last.deletingLastPathComponent()) }
        let repository = ancestors.first { manager.fileExists(atPath: $0.appendingPathComponent(".git").path) }
        let levels = repository.map { root in Array(ancestors.prefix(through: ancestors.firstIndex(of: root)!)) } ?? [folder]
        var candidates = ancestors.map { $0.appendingPathComponent(".mcp.json") }
        var settingsRoots = levels

        // Linked worktrees can also load settings from the main checkout.
        if let repository,
           let data = try? readConfiguration(repository.appendingPathComponent(".git"), limit: 16_384),
           let link = String(data: data, encoding: .utf8),
           link.hasPrefix("gitdir:") {
            let path = link.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
            let gitDirectory = URL(fileURLWithPath: path, relativeTo: repository).standardizedFileURL
            if let data = try? readConfiguration(gitDirectory.appendingPathComponent("commondir"), limit: 16_384),
               let common = String(data: data, encoding: .utf8) {
                let commonDirectory = URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: gitDirectory)
                    .standardizedFileURL.resolvingSymlinksInPath()
                if commonDirectory.lastPathComponent == ".git" { settingsRoots.append(commonDirectory.deletingLastPathComponent()) }
            }
        }
        candidates += settingsRoots.flatMap { root in
            [".claude/settings.json", ".claude/settings.local.json"].map { root.appendingPathComponent($0) }
        }
        var fingerprints: [String: String] = [:]
        for file in Set(candidates) where manager.fileExists(atPath: file.path) {
            // Unreadable configuration fails closed rather than being silently trusted.
            let data = try readConfiguration(file)
            fingerprints[file.path] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return fingerprints
    }

    private static func readConfiguration(_ file: URL, limit: Int = 2 * 1024 * 1024) throws -> Data {
        // A configuration path can be supplied by an untrusted checkout. Never block
        // the UI on a FIFO or read an unbounded file while deciding whether to trust it.
        let descriptor = open(file.path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit,
              let data = try handle.read(upToCount: limit + 1), data.count <= limit else {
            throw AgentError.launchFailed("Configuration must be a regular file no larger than \(limit) bytes: \(file.path)")
        }
        return data
    }

    public static func changedFiles(in snapshot: [String: String], accepted: [String: String]?) -> [String] {
        snapshot.keys.filter { accepted?[$0] != snapshot[$0] }.sorted()
    }
}
