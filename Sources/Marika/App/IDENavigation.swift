import Foundation
import MarikaCore

struct EditorCodeLocation: Identifiable {
    var id: String { "\(path):\(line):\(column)" }
    var path: String
    var line: Int
    var column: Int
    var length: Int
    var preview: String
    var previewLine: Int
}

extension IDEWorkspace {
    func locations(in document: CodeDocument, text: String, offset: Int, references: Bool) async throws -> [EditorCodeLocation] {
        let server = try await service(for: document)
        try Task.checkCancellation()
        guard document.text == text else { return [] }
        try await server.synchronize(path: document.path, text: text)
        let response = try await server.request(references ? "textDocument/references" : "textDocument/definition", path: document.path,
            position: SourcePosition.at(offset: offset, in: text), extra: references ? ["context": ["includeDeclaration": true]] : [:])
        try Task.checkCancellation()
        guard document.text == text else { return [] }
        var result: [EditorCodeLocation] = []
        for location in SourceNavigation.locations(response).prefix(100) {
            guard let path = await server.localPath(location.uri) else { continue }
            let source = (try? await editor.previewText(path)) ?? ""
            let lines = source.components(separatedBy: "\n")
            let start = max(0, min(lines.count, location.line - 3))
            let end = min(lines.count, location.line + 3)
            result.append(EditorCodeLocation(path: path, line: location.line, column: location.column, length: location.length,
                preview: lines[start..<max(start, end)].joined(separator: "\n"), previewLine: start + 1))
        }
        return result
    }

    func open(_ location: EditorCodeLocation) async {
        await editor.navigate(to: location.path, line: location.line, column: location.column, length: location.length)
    }
}
