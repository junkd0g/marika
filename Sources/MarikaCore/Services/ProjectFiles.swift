import Foundation
import UniformTypeIdentifiers

public struct ProjectFileEntry: Identifiable, Equatable, Sendable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var isSymbolicLink: Bool
    public var id: String { path }
}

public struct TextFileSnapshot: Sendable {
    public var path: String
    public var text: String
    public var data: Data
    public var encoding: String.Encoding
    public var hasUTF8BOM: Bool
}

public struct FilePreviewSnapshot: Equatable, Sendable {
    public let url: URL
    public let typeName: String
    public let byteCount: Int64
    public let modifiedAt: Date?
}

public enum ProjectFileContent: Sendable {
    case text(TextFileSnapshot)
    case preview(FilePreviewSnapshot)
}

public enum ProjectFileError: LocalizedError, Equatable {
    case outsideProject, notRegularFile, tooLarge, notText, changedOnDisk

    public var errorDescription: String? {
        switch self {
        case .outsideProject: "This file is outside the project folder."
        case .notRegularFile: "Choose a file to open."
        case .tooLarge: "This file is too large for the editor. The limit is 2 MB."
        case .notText: "This file isn't supported text. Open it in its default app instead."
        case .changedOnDisk: "This file changed on disk. Reload it or review your edits before overwriting it."
        }
    }
}

/// File access stays off the main actor, is limited to the project, and checks the saved
/// bytes before writing so an agent's changes cannot be silently overwritten.
public actor ProjectFiles: WorkspaceFiles {
    public let root: URL
    public static let maxFileBytes = 2 * 1024 * 1024
    private static let omitted = Set([".git", ".build", ".swiftpm", "node_modules", "DerivedData", ".DS_Store"])

    public init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func url(for path: String) throws -> URL {
        guard !path.hasPrefix("/") else { throw ProjectFileError.outsideProject }
        let candidate = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.path == "/" ? "/" : root.path + "/"
        guard candidate == root || candidate.path.hasPrefix(prefix) else { throw ProjectFileError.outsideProject }
        return candidate
    }

    public func entries(in path: String = "") throws -> [ProjectFileEntry] {
        let directory = try url(for: path)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
            .filter { !Self.omitted.contains($0.lastPathComponent) }
            .map { child in
                let values = try child.resourceValues(forKeys: keys)
                let link = values.isSymbolicLink == true
                return ProjectFileEntry(
                    path: path.isEmpty ? child.lastPathComponent : path + "/" + child.lastPathComponent,
                    name: child.lastPathComponent, isDirectory: values.isDirectory == true && !link, isSymbolicLink: link)
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    public func filePaths(limit: Int = 20_000) throws -> [String] {
        guard limit > 0, let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var paths: [String] = []
        // Enumerate relative names directly: macOS can spell the same temporary root with
        // /var or /private/var, so trimming an absolute URL by character count is unreliable.
        for case let path as String in enumerator {
            if Task.isCancelled { break }
            let url = root.appendingPathComponent(path)
            if Self.omitted.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { enumerator.skipDescendants() }
            if values?.isDirectory != true {
                paths.append(path)
                if paths.count >= limit { break }
            }
        }
        return paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func readData(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ProjectFileError.notRegularFile }
        guard (values.fileSize ?? 0) <= Self.maxFileBytes else { throw ProjectFileError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maxFileBytes + 1) ?? Data()
        guard data.count <= Self.maxFileBytes else { throw ProjectFileError.tooLarge }
        return data
    }

    public func read(_ path: String) throws -> TextFileSnapshot {
        let data = try readData(at: url(for: path))
        let encoding: String.Encoding
        let bom = data.starts(with: [0xEF, 0xBB, 0xBF])
        let content: Data
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16
            content = data
        } else {
            guard !data.contains(0) else { throw ProjectFileError.notText }
            encoding = .utf8
            content = bom ? Data(data.dropFirst(3)) : data
        }
        guard let text = String(data: content, encoding: encoding),
            !text.unicodeScalars.contains(where: { $0.value == 0 })
        else { throw ProjectFileError.notText }
        return TextFileSnapshot(path: path, text: text, data: data, encoding: encoding, hasUTF8BOM: bom)
    }

    /// Keep text editable and let the system preview media and other binary formats.
    /// Preview URLs go through the same project-boundary checks as text reads and writes.
    public func open(_ path: String) throws -> ProjectFileContent {
        let preview = try preview(path)
        let type = UTType(filenameExtension: preview.url.pathExtension)
        // macOS also associates .ts with MPEG transport streams. Prefer the source
        // interpretation for ambiguous code extensions, then fall back to a binary preview.
        let sourceExtensions: Set<String> = ["ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs", "py", "go", "swift", "rs", "kt", "kts", "java", "cs", "c", "cc", "cpp", "h", "hpp", "m", "mm", "sh", "bash", "zsh", "rb", "php", "scala", "dart", "vue", "svelte", "sql", "graphql", "gql", "proto", "css", "scss", "json", "toml", "yaml", "yml", "md", "txt"]
        if !sourceExtensions.contains(preview.url.pathExtension.lowercased()), let type, type.conforms(to: .image) || type.conforms(to: .pdf)
            || type.conforms(to: .audiovisualContent) {
            return .preview(preview)
        }
        do { return .text(try read(path)) }
        catch ProjectFileError.notText { return .preview(preview) }
        catch ProjectFileError.tooLarge { return .preview(preview) }
    }

    public func preview(_ path: String) throws -> FilePreviewSnapshot {
        let target = try url(for: path)
        let values = try target.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true else { throw ProjectFileError.notRegularFile }
        return FilePreviewSnapshot(url: target,
            typeName: UTType(filenameExtension: target.pathExtension)?.localizedDescription ?? "File",
            byteCount: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate)
    }

    public func write(_ text: String, replacing snapshot: TextFileSnapshot, overwrite: Bool = false) throws -> TextFileSnapshot {
        let destination = try url(for: snapshot.path)
        // A deleted file is also an external change. An explicit overwrite may recreate it.
        if !overwrite {
            guard let current = try? readData(at: destination), current == snapshot.data else {
                throw ProjectFileError.changedOnDisk
            }
        } else if FileManager.default.fileExists(atPath: destination.path) {
            guard try destination.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw ProjectFileError.notRegularFile
            }
        }
        guard var data = text.data(using: snapshot.encoding) else { throw ProjectFileError.notText }
        if snapshot.hasUTF8BOM { data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0) }
        guard data.count <= Self.maxFileBytes else { throw ProjectFileError.tooLarge }
        let permissions = try? FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions]
        try data.write(to: destination, options: .atomic)
        if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path) }
        return TextFileSnapshot(
            path: snapshot.path, text: text, data: data, encoding: snapshot.encoding, hasUTF8BOM: snapshot.hasUTF8BOM)
    }
}
