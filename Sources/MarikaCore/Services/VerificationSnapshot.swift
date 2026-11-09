import CryptoKit
import Foundation

/// A content fingerprint, not a copy of source code. Stored with a test result so it
/// can be checked after app restart, external edits, renames, additions and deletions.
public struct VerificationSnapshot: Codable, Equatable, Hashable, Sendable {
    public let root: String
    public let digest: String
    public let fileCount: Int
    public let version: Int

    public static func capture(at root: URL) async throws -> Self {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let discovered = await Git(environment: [:]).verificationPaths(at: root)
        // A standalone project can live inside an ignored folder of a parent
        // repository. An empty Git listing must not mean "no test inputs".
        let paths = discovered?.isEmpty == false ? discovered : nil
        try Task.checkCancellation()
        let work = Task.detached(priority: .utility) { try capture(root, paths: paths) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private static let omitted = Set([".git", ".build", ".swiftpm", "node_modules", "DerivedData", "target",
        ".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".next", ".nuxt",
        ".turbo", ".cache", "coverage", "dist", "build", ".DS_Store", ".coverage"])

    private static func capture(_ root: URL, paths trackedPaths: [String]?) throws -> Self {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SnapshotError("The checked project folder is unavailable.")
        }
        var paths = trackedPaths ?? []
        if trackedPaths == nil {
            var directories = [""]
            var visited = 0
            while let directory = directories.popLast() {
                let parent = root.appendingPathComponent(directory)
                for name in try manager.contentsOfDirectory(atPath: parent.path) {
                    try Task.checkCancellation()
                    if omitted.contains(name) || ["pyc", "profraw", "profdata"].contains((name as NSString).pathExtension) { continue }
                    let relative = directory.isEmpty ? name : directory + "/" + name
                    let attributes = try manager.attributesOfItem(atPath: root.appendingPathComponent(relative).path)
                    if attributes[.type] as? FileAttributeType == .typeDirectory { directories.append(relative) }
                    else { paths.append(relative) }
                    visited += 1
                    guard visited <= 50_000 else { throw SnapshotError("This project exceeds the 50,000-file verification limit.") }
                }
            }
        }
        guard paths.count <= 50_000 else { throw SnapshotError("This project exceeds the 50,000-file verification limit.") }
        var hash = SHA256(), total = 0, count = 0
        for path in paths.sorted() {
            try Task.checkCancellation()
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw SnapshotError("An input path is outside the project.") }
            let url = root.appendingPathComponent(path)
            // Missing tracked files are part of the snapshot through their absence.
            let attributes: [FileAttributeKey: Any]
            do { attributes = try manager.attributesOfItem(atPath: url.path) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
            let resolved = url.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root.path + "/") else {
                throw SnapshotError("\(path) links outside this project; its test inputs cannot be verified.")
            }
            let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { throw SnapshotError("\(path) is not a regular test input.") }
            guard (values.fileSize ?? Int.max) <= 50_000_000, total + (values.fileSize ?? 0) <= 250_000_000 else {
                throw SnapshotError("The project exceeds the verification snapshot size limit.")
            }
            let data = try Data(contentsOf: resolved, options: .mappedIfSafe)
            total += data.count
            guard total <= 250_000_000 else { throw SnapshotError("The project exceeds the verification snapshot size limit.") }
            let after = try resolved.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard values.fileSize == after.fileSize, values.contentModificationDate == after.contentModificationDate else {
                throw SnapshotError("\(path) changed while its test inputs were being checked.")
            }
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let target = attributes[.type] as? FileAttributeType == .typeSymbolicLink ? try manager.destinationOfSymbolicLink(atPath: url.path) : ""
            hash.update(data: Data("\(path.utf8.count):\(path):\(mode):\(target.utf8.count):\(target):\(data.count):".utf8))
            hash.update(data: data)
            count += 1
        }
        return Self(root: root.path, digest: hash.finalize().map { String(format: "%02x", $0) }.joined(), fileCount: count, version: 1)
    }

    private struct SnapshotError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
