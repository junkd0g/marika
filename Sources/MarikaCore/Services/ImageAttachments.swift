import Foundation
import UniformTypeIdentifiers

public actor ImageAttachments {
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func copy(from url: URL) throws -> ImageAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let source = url.resolvingSymlinksInPath()
        guard let type = UTType(filenameExtension: source.pathExtension), type.conforms(to: .image),
              try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return try write(ext: source.pathExtension, type: type.preferredMIMEType ?? "application/octet-stream") {
            try FileManager.default.copyItem(at: source, to: $0)
        }
    }

    public func savePNG(_ data: Data) throws -> ImageAttachment {
        try write(ext: "png", type: "image/png") { try data.write(to: $0, options: .atomic) }
    }

    private func write(ext: String, type: String, _ copy: (URL) throws -> Void) throws -> ImageAttachment {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext.lowercased())
        do {
            try copy(url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return ImageAttachment(path: url.path, mediaType: type)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
