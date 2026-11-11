import Foundation
import MarikaCore

extension IDEWorkspace {
    func designSymbols(path: String) async throws -> [SourceSymbol] {
        let text = try await editor.currentSourceText(path)
        let server = try await service(forPath: path)
        let result = try await server.symbols(path: path, text: text)
        guard try await editor.currentSourceText(path) == text else { throw SymbolLookupError.changed }
        return result.filter { (try? SourcePosition.offset($0.position.json, in: text)) != nil }
    }
}

extension AppModel {
    func designSymbols(projectID: UUID, path: String) async throws -> [SourceSymbol] {
        guard let project = project(id: projectID), DesignSourceLink(kind: .file, target: path).isValid else {
            throw DesignToolError("This project or file link is unavailable.")
        }
        // The project's main repository owns Design links, independently of the active code tab.
        var primary = project; primary.selectedRepositoryPath = nil
        let active = editors[projectID]
        let editor = editor(for: primary)
        if project.editorURL != primary.url { editors[projectID] = active }
        await editorRestorations[projectID]?[primary.url.path]?.value
        return try await ide(for: primary, editor: editor).designSymbols(path: path)
    }

    func designSymbol(_ link: DesignSourceLink, projectID: UUID) async throws -> SourceSymbol {
        try SourceSymbols.resolve(link, in: await designSymbols(projectID: projectID, path: link.target))
    }

    func openDesignSymbolReferences(_ link: DesignSourceLink, projectID: UUID) async throws {
        try await openDesignLink(link, projectID: projectID)
        guard let project = project(id: projectID), let editor = editors[projectID], editor.selectedDocument != nil else { return }
        let workspace = ide(for: project, editor: editor)
        workspace.perform("References")
    }
}
