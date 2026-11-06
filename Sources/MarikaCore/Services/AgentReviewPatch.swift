import CryptoKit
import Foundation

public struct AgentReviewHunk: Identifiable, Sendable, Equatable {
    public let id: String
    public let path: String
    public let patch: Data
    public let display: DiffFile
    public let oldStart: Int
    public let newStart: Int
    public let wholeFile: Bool
    public var additions: Int { display.additions }
    public var deletions: Int { display.deletions }
}

public struct AgentReviewFileState: Sendable, Equatable {
    let digest: String
    let mode: Int

    static func capture(_ path: String, root: URL) throws -> Self {
        let url = root.appendingPathComponent(path)
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard parent.path == root.path || parent.path.hasPrefix(root.path + "/") else {
            throw AgentWorktreeError(message: "A reviewed path points outside the project: \(path)")
        }
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return Self(digest: "missing", mode: 0)
        }
        let data: Data
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            data = Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8)
        } else {
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw AgentWorktreeError(message: "This reviewed path is not a regular file: \(path)")
            }
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        }
        return Self(digest: AgentReviewPatch.digest(data), mode: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0)
    }
}

/// Keeps the original patch bytes, including no-newline markers and binary/file metadata.
public enum AgentReviewPatch {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    public static func hunks(_ patch: Data, paths: [String]) throws -> [AgentReviewHunk] {
        var sections: [Data] = []
        for raw in patch.split(separator: 10, omittingEmptySubsequences: false).dropLast(patch.last == 10 ? 1 : 0) {
            if raw.starts(with: Data("diff --git ".utf8)) { sections.append(Data()) }
            guard !sections.isEmpty else { continue }
            sections[sections.count - 1].append(contentsOf: raw)
            sections[sections.count - 1].append(10)
        }
        guard sections.count == paths.count else { throw AgentWorktreeError(message: "The changed-file list no longer matches the patch. Refresh the review.") }
        return zip(sections, paths).flatMap { section, path -> [AgentReviewHunk] in
            let text = String(data: section, encoding: .utf8)
            let lines = text?.components(separatedBy: "\n") ?? []
            let start = lines.firstIndex { $0.hasPrefix("@@ ") }
            let metadata = lines.prefix(start ?? lines.count)
            let wholeFile = text == nil || start == nil || metadata.contains {
                $0.hasPrefix("new file mode ") || $0.hasPrefix("deleted file mode ") || $0.hasPrefix("old mode ") || $0.hasPrefix("new mode ") || $0.hasPrefix("GIT binary patch")
            }
            var display = DiffParser.parse(text ?? "", defaultPath: path).first ?? DiffFile(path: path, isBinary: true)
            display.path = path
            if text == nil || metadata.contains("GIT binary patch") { display.isBinary = true }
            if wholeFile {
                return [AgentReviewHunk(id: digest(section), path: path, patch: section, display: display,
                    oldStart: display.lines.compactMap(\.oldNumber).first ?? 1, newStart: display.lines.compactMap(\.newNumber).first ?? 1, wholeFile: true)]
            }
            let header = metadata.filter { $0.hasPrefix("diff --git ") || $0.hasPrefix("--- ") || $0.hasPrefix("+++ ") }.joined(separator: "\n") + "\n"
            var chunks: [[String]] = []
            for line in lines.dropFirst(start!) {
                if line.hasPrefix("@@ ") { chunks.append([]) }
                if !chunks.isEmpty { chunks[chunks.count - 1].append(line) }
            }
            return chunks.map { chunk in
                let hunk = chunk.joined(separator: "\n") + (chunk.last == "" ? "" : "\n")
                let bytes = Data((header + hunk).utf8)
                var display = DiffParser.parse(header + hunk, defaultPath: path).first ?? DiffFile(path: path)
                display.path = path
                return AgentReviewHunk(id: digest(bytes), path: path, patch: bytes, display: display,
                    oldStart: display.lines.compactMap(\.oldNumber).first ?? 1, newStart: display.lines.compactMap(\.newNumber).first ?? 1, wholeFile: false)
            }
        }
    }
}
