import AppKit
import MarikaCore

/// Shared editor creation, restoration and unsaved-buffer handling.
extension AppModel {
    func editor(for project: Project) -> CodeWorkspace {
        if let existing = repositoryEditors[project.id]?[project.editorURL.path] { editors[project.id] = existing; return existing }
        let remoteFiles: (any WorkspaceFiles)? = project.runtime?.kind == .ssh ? RemoteFiles(runtime: project.runtime!, cache: project.editorURL, environment: toolEnvironment) : nil
        let editor = CodeWorkspace(root: project.editorURL, files: remoteFiles)
        editor.onSave = { [weak self] in
            guard let self else { return }
            for session in self.controllers.values where session.meta.projectID == project.id { session.apply(.filesChanged) }
        }
        editor.onStateChange = { [weak self] in self?.scheduleSave() }
        editors[project.id] = editor
        repositoryEditors[project.id, default: [:]][project.editorURL.path] = editor
        let ide = ide(for: project, editor: editor)
        editor.beforeSave = { [weak ide] document in
            if let ide, ide.preferences.formatOnSave { try await ide.format(document) }
        }
        if let saved = project.editorURL == project.url ? project.layout : project.repositoryLayouts?[project.editorURL.path], !saved.files.isEmpty {
            editorRestorations[project.id, default: [:]][project.editorURL.path] = Task { [weak self] in
                await editor.restore(saved)
                self?.editorRestorations[project.id]?[project.editorURL.path] = nil
            }
        }
        return editor
    }

    /// Called before quitting or removing a project. Switching tabs never discards buffers.
    func confirmClosingEditors(_ editors: [CodeWorkspace]) async -> Bool {
        let modified = editors.flatMap { editor in editor.modifiedDocuments.map { (editor, $0) } }
        guard !modified.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = modified.count == 1 ? "Save your file changes?" : "Save changes to \(modified.count) files?"
        alert.informativeText = modified.map { $0.1.path }.joined(separator: "\n") + "\n\nUnsaved changes will be lost if you discard them."
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for (editor, document) in modified {
                guard await editor.save(document) else {
                    let failure = NSAlert()
                    failure.messageText = "Couldn't save \(document.name)"
                    failure.informativeText = editor.errorMessage ?? "Return to the editor to review your changes."
                    failure.addButton(withTitle: "Return to Editor")
                    failure.runModal()
                    if let project = workspace.projects.first(where: { $0.url == editor.root }) {
                        projectTabs[project.id] = .code
                        selectedSessionID = sessions(in: project).first?.id
                    }
                    editor.selectedDocumentID = document.id
                    return false
                }
            }
            return editors.allSatisfy { $0.modifiedDocuments.isEmpty }
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }
}
