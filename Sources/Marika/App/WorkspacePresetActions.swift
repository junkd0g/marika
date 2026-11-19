import AppKit
import MarikaCore

extension AppModel {
    func applyViewPreset(_ preset: WorkspaceViewPreset, project: Project) {
        if selectedProject?.id != project.id { openProject(project) }
        updateLayout(preset.applying(to: layout(for: project.id)), for: project.id)
        if let secondary = preset.secondary { selectProjectTab(secondary) }
        selectProjectTab(preset.primary)
        showsInspector = preset.showsInspector
    }

    func saveViewPreset(name: String, project: Project) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else { throw DesignToolError("Use a layout name of 1–60 characters.") }
        var presets = self.project(id: project.id)?.viewPresets ?? []
        let index = presets.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard index != nil || presets.count < 20 else { throw DesignToolError("Keep up to 20 saved layouts per project.") }
        let preset = WorkspaceViewPreset(id: index.map { presets[$0].id } ?? UUID(), name: name, layout: layout(for: project.id))
        if let index { presets[index] = preset } else { presets.append(preset) }
        updateProject(project.id) { $0.viewPresets = presets }
    }

    func promptForViewPreset(project: Project) {
        let alert = NSAlert()
        alert.messageText = "Save workspace layout"
        alert.informativeText = "Save the visible views and split arrangement for this project. Reusing a name updates that layout."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Layout name"
        alert.accessoryView = field; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try saveViewPreset(name: field.stringValue, project: project) }
        catch { let failure = NSAlert(error: error); failure.runModal() }
    }
}
