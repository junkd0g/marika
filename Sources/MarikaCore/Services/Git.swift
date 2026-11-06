import Foundation
import Darwin

public struct GitChange: Equatable, Hashable, Sendable, Identifiable {
    public enum Status: String, Sendable {
        case modified
        case added
        case deleted
        case renamed
        case untracked
        case conflicted

        public var letter: String {
            switch self {
            case .modified: "M"
            case .added: "A"
            case .deleted: "D"
            case .renamed: "R"
            case .untracked: "U"
            case .conflicted: "!"
            }
        }
    }

    public var path: String
    public var status: Status
    public var additions: Int
    public var deletions: Int

    public var id: String { path }

    public init(path: String, status: Status, additions: Int = 0, deletions: Int = 0) {
        self.path = path
        self.status = status
        self.additions = additions
        self.deletions = deletions
    }
}

public struct GitSnapshot: Equatable, Sendable {
    public var isRepository: Bool
    public var branch: String?
    public var changes: [GitChange]
    public var error: String?

    public init(isRepository: Bool = false, branch: String? = nil, changes: [GitChange] = [], error: String? = nil) {
        self.isRepository = isRepository
        self.branch = branch
        self.changes = changes
        self.error = error
    }

    public var additions: Int { changes.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { changes.reduce(0) { $0 + $1.deletions } }
}

/// Read-only git queries for the changes panel.
public struct Git: Sendable {
    public var environment: [String: String]
    private var executable: URL {
        // /usr/bin/git is an Xcode shim; use a known system installation directly.
        let paths = ["/Library/Developer/CommandLineTools/usr/bin/git", "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
        return URL(fileURLWithPath: paths.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git")
    }
    private static let maxPreviewBytes = 512 * 1024

    public init(environment: [String: String]) {
        self.environment = environment
    }

    public func snapshot(at directory: URL) async -> GitSnapshot {
        guard repository(at: directory) != nil else { return GitSnapshot() }
        let branch = await run(["branch", "--show-current"], in: directory)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let status = await run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=all"], in: directory) else {
            return GitSnapshot(isRepository: true, branch: branch, error: "Couldn't read Git changes safely. Check that Git and the repository are available.")
        }
        var changes = Self.parseStatus(status)
        let counts = Self.parseNumstat(await run(["diff", "HEAD", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all", "--numstat", "-z"], in: directory) ?? "")
        for index in changes.indices {
            if let count = counts[changes[index].path] {
                changes[index].additions = count.additions
                changes[index].deletions = count.deletions
            } else if changes[index].status == .untracked {
                changes[index].additions = lineCount(of: changes[index].path, in: directory)
            }
        }
        return GitSnapshot(isRepository: true, branch: branch?.isEmpty == true ? nil : branch, changes: changes)
    }

    public func diff(for change: GitChange, at directory: URL) async -> DiffFile {
        if change.status == .untracked {
            guard let data = previewData(change.path, in: directory),
                let text = String(data: data, encoding: .utf8)
            else {
                return DiffFile(path: change.path, isBinary: true)
            }
            return DiffFile(path: change.path, newContent: text)
        }
        let output = await run(["diff", "HEAD", "--no-color", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all", "--", change.path], in: directory) ?? ""
        return DiffParser.parse(output, defaultPath: change.path).first ?? DiffFile(path: change.path)
    }

    private func run(_ arguments: [String], in directory: URL) async -> String? {
        guard let repository = repository(at: directory) else { return nil }
        let binary = executable.path
        // No writes, network, or execution of helpers, even if repository config changes
        // between discovery and execution. Failure never falls back to unsandboxed Git.
        let profile = """
        (version 1)
        (deny default)
        (allow file-read*)
        (allow file-write-data (literal "/dev/null"))
        (allow process-fork)
        (allow process-exec (literal "\(binary)"))
        (allow sysctl-read)
        (allow mach-lookup)
        (allow signal (target self))
        """
        let safeEnvironment = [
            "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "GIT_ATTR_NOSYSTEM": "1", "GIT_NO_REPLACE_OBJECTS": "1",
        ]
        let options = ["--no-pager", "--git-dir=" + repository.git.path, "--work-tree=" + repository.root.path,
                       "-C", directory.path, "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
                       "-c", "core.attributesFile=/dev/null", "-c", "core.quotePath=false", "-c", "submodule.recurse=false"]
        guard
            let result = try? await Command.run(
                URL(fileURLWithPath: "/usr/bin/sandbox-exec"), ["-p", profile, binary] + options + arguments,
                environment: safeEnvironment, timeout: 15),
            result.succeeded
        else { return nil }
        return result.output
    }

    private func repository(at directory: URL) -> (root: URL, git: URL)? {
        var root = directory.standardizedFileURL.resolvingSymlinksInPath()
        while true {
            let git = root.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return (root, git) }
                guard let data = previewData(".git", in: root), data.count < 16_384,
                      let link = String(data: data, encoding: .utf8), link.hasPrefix("gitdir:") else { return nil }
                let path = link.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty else { return nil }
                return (root, URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL)
            }
            guard root.path != "/" else { return nil }
            root.deleteLastPathComponent()
        }
    }

    private func previewData(_ path: String, in directory: URL) -> Data? {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let parts = path.split(separator: "/").map(String.init)
        guard !path.hasPrefix("/"), !parts.isEmpty, !parts.contains(".."), !parts.contains("."), !path.contains("\0") else { return nil }
        // Open each directory relative to its descriptor so a replaced symlink cannot
        // redirect an untracked preview outside the project between checking and reading.
        var parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { return nil }
        defer { close(parent) }
        for part in parts.dropLast() {
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { return nil }
            close(parent)
            parent = next
        }
        let descriptor = openat(parent, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= Self.maxPreviewBytes,
              let data = try? handle.read(upToCount: Self.maxPreviewBytes + 1), data.count <= Self.maxPreviewBytes else { return nil }
        return data
    }

    private func lineCount(of path: String, in directory: URL) -> Int {
        guard let data = previewData(path, in: directory), !data.contains(0) else { return 0 }
        let newlines = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        return data.last == 0x0A || data.isEmpty ? newlines : newlines + 1
    }

    static func parseStatus(_ output: String) -> [GitChange] {
        var changes: [GitChange] = []
        var entries = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let entry = entries.next() {
            guard entry.count > 3 else { continue }
            let code = entry.prefix(2)
            let path = String(entry.dropFirst(3))
            let status: GitChange.Status
            if code == "??" {
                status = .untracked
            } else if code.contains("U") || code == "AA" || code == "DD" {
                status = .conflicted
            } else if code.contains("R") {
                status = .renamed
                _ = entries.next()  // Renames carry the old path as a second entry.
            } else if code.contains("D") {
                status = .deleted
            } else if code.contains("A") {
                status = .added
            } else {
                status = .modified
            }
            changes.append(GitChange(path: path, status: status))
        }
        return changes.sorted { $0.path < $1.path }
    }

    static func parseNumstat(_ output: String) -> [String: (additions: Int, deletions: Int)] {
        var counts: [String: (additions: Int, deletions: Int)] = [:]
        var entries = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let entry = entries.next() {
            let fields = entry.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            var path = String(fields[2])
            if path.isEmpty {
                // Renames are reported as `0\t0\t\0old\0new`.
                _ = entries.next()
                path = entries.next().map(String.init) ?? ""
            }
            counts[path] = (Int(fields[0]) ?? 0, Int(fields[1]) ?? 0)
        }
        return counts
    }
}
