import CryptoKit
import Foundation

public struct DesignImportSourceSnapshot: Sendable {
    public let files: [DesignImportFile]
    public let excerpts: String
    public let contents: [String: Data]
}

public enum DesignImportSources {
    public static let maximumFiles = 40
    private static let extensions: Set<String> = ["swift", "kt", "kts", "html", "htm", "jsx", "tsx", "js", "ts", "vue", "css", "scss", "sass", "less", "xml", "xib", "storyboard"]
    private static let omitted: Set<String> = [".git", ".build", ".swiftpm", ".gradle", ".idea", "node_modules", "vendor", "Pods", "DerivedData", "build", "dist", "coverage", "out", "target", "__tests__"]

    public static func discover(at root: URL) async throws -> [DesignImportFile] {
        try await Task.detached(priority: .userInitiated) {
            let root = root.standardizedFileURL.resolvingSymlinksInPath()
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
                throw DesignToolError("The project folder could not be read.")
            }
            var files: [DesignImportFile] = [], inspected = 0
            while let url = enumerator.nextObject() as? URL {
                try Task.checkCancellation(); inspected += 1
                if inspected > 30_000 || files.count >= 600 { break }
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                if values.isSymbolicLink == true || omitted.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
                guard values.isDirectory != true, extensions.contains(url.pathExtension.lowercased()),
                      let size = values.fileSize, size <= 200_000 else { continue }
                let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
                let prefix = root.path == "/" ? "/" : root.path + "/"
                guard canonical.path.hasPrefix(prefix) else { continue }
                let path = String(canonical.path.dropFirst(prefix.count))
                guard !path.hasSuffix(".d.ts"), !path.lowercased().contains(".min."), !path.lowercased().contains("generated") else { continue }
                let data = try boundedRead(url)
                guard let text = String(data: data, encoding: .utf8) else { continue }
                let sample = String(text.prefix(16_000))
                let framework = framework(path: path, sample: sample)
                let priority = ["view", "screen", "page", "component", "theme", "style", "layout", "app."].filter { path.lowercased().contains($0) }.count * 10
                    + (framework == "JavaScript / TypeScript" ? 0 : 20)
                files.append(DesignImportFile(path: path, framework: framework, bytes: size, priority: priority))
            }
            return files.sorted { $0.priority == $1.priority ? $0.path < $1.path : $0.priority > $1.priority }
        }.value
    }

    public static func capture(_ paths: [String], at root: URL) async throws -> DesignImportSourceSnapshot {
        try await Task.detached(priority: .userInitiated) {
            guard !paths.isEmpty, paths.count <= maximumFiles, Set(paths).count == paths.count else {
                throw DesignToolError("Select between 1 and \(maximumFiles) UI source files.")
            }
            var files: [DesignImportFile] = [], contents: [String: Data] = [:], excerpts = "", bytes = 0
            let excerptLimit = min(3_000, 16_000 / paths.count)
            for path in paths.sorted() {
                try Task.checkCancellation()
                let data = try source(path, at: root)
                bytes += data.count
                guard bytes <= 2_000_000, let text = String(data: data, encoding: .utf8) else { throw DesignToolError("Select UTF-8 source files totalling at most 2 MB.") }
                files.append(DesignImportFile(path: path, framework: framework(path: path, sample: text), bytes: data.count,
                    digest: digest(data), lines: text.components(separatedBy: "\n").count))
                contents[path] = data
                excerpts += "\nSOURCE " + path + "\n" + String(text.prefix(excerptLimit)) + "\nEND SOURCE\n"
            }
            return DesignImportSourceSnapshot(files: files, excerpts: excerpts, contents: contents)
        }.value
    }

    public static func workingDirectory(for id: UUID) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("marika-design-source-" + id.uuidString, isDirectory: true)
    }

    /// Run the agent against selected copies, without loading project-local hooks or MCP configuration.
    public static func stage(_ snapshot: DesignImportSourceSnapshot, id: UUID) async throws {
        try await Task.detached {
            let root = workingDirectory(for: id)
            guard !FileManager.default.fileExists(atPath: root.path) else { throw DesignToolError("This analysis folder already exists. Start a new import.") }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for file in snapshot.files {
                try Task.checkCancellation()
                try validatePath(file.path)
                guard let data = snapshot.contents[file.path], file.digest == digest(data) else { throw DesignToolError("The source snapshot is incomplete.") }
                let destination = root.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try data.write(to: destination, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
            }
        }.value
    }

    public static func discardStage(id: UUID) async {
        _ = await Task.detached { try? FileManager.default.removeItem(at: workingDirectory(for: id)) }.value
    }

    public static func verify(_ files: [DesignImportFile], at root: URL) async throws {
        try await Task.detached {
            for file in files {
                try Task.checkCancellation()
                guard let expected = file.digest, digest(try source(file.path, at: root)) == expected else {
                    throw DesignToolError("Source changed since analysis: \(file.path). Generate a fresh draft before importing.")
                }
            }
        }.value
    }

    private static func source(_ path: String, at root: URL) throws -> Data {
        try validatePath(path)
        let url = try APICollection.projectFile(path, root: root)
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 200_000 else {
            throw DesignToolError("Source files must be under 200 KB. Choose a smaller component.")
        }
        return try boundedRead(url)
    }

    private static func validatePath(_ path: String) throws {
        guard extensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
              path.count <= 2_048, !path.hasPrefix("/"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !path.split(separator: "/").contains(where: { $0 == ".." || omitted.contains(String($0)) }) else {
            throw DesignToolError("Choose a UI source file inside this project.")
        }
    }

    private static func boundedRead(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 200_001) ?? Data()
        guard data.count <= 200_000 else { throw DesignToolError("Source files must be under 200 KB.") }
        return data
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func framework(path: String, sample: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "swift": return sample.contains("SwiftUI") ? "SwiftUI" : "Swift / UIKit"
        case "kt", "kts": return sample.contains("@Composable") || sample.contains("androidx.compose") ? "Kotlin / Compose" : "Kotlin / Android"
        case "vue": return "Vue"
        case "jsx", "tsx": return "React"
        case "html", "htm": return "HTML"
        case "css", "scss", "sass", "less": return "Styles"
        case "xib", "storyboard": return "UIKit / Interface Builder"
        case "xml": return "Android XML"
        default: return sample.contains("react") ? "React" : sample.contains("vue") ? "Vue" : "JavaScript / TypeScript"
        }
    }
}
