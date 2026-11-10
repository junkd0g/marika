#if DEBUG
import Foundation
import MarikaCore
import AppKit

@MainActor
enum DebugDesignChecks {
    static func render(_ model: AppModel, to directory: String) throws {
        guard DebugFixtureSettings.value("MARIKA_DATA") != nil, let project = model.selectedProject else {
            throw DesignToolError("Export checks require an isolated fixture project.")
        }
        let document = model.design(for: project).document
        for (name, selection) in [("canvas", Set<UUID>()), ("selection", Set(document.nodes.filter { !$0.isHidden }.prefix(1).map(\.id)))] {
            let plan = try DesignExportPlan(document: document, selection: selection)
            let data = try DesignRenderer.png(document: document, selection: selection)
            guard let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
                  abs(Double(bitmap.pixelsWide) - plan.bounds.width * plan.scale) < 2,
                  abs(Double(bitmap.pixelsHigh) - plan.bounds.height * plan.scale) < 2 else {
                throw DesignToolError("Export dimensions differ from visible artwork.")
            }
            var ink = 0
            for row in 0..<20 {
                for column in 0..<20 {
                    if let color = bitmap.colorAt(x: column * bitmap.pixelsWide / 20, y: row * bitmap.pixelsHigh / 20)?.usingColorSpace(.deviceRGB),
                       min(color.redComponent, color.greenComponent, color.blueComponent) < 0.98 { ink += 1 }
                }
            }
            guard ink > 5 else { throw DesignToolError("Exported image is blank.") }
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"), options: .atomic)
        }
    }

    static func run(_ model: AppModel) async throws {
        guard DebugFixtureSettings.value("MARIKA_DATA") != nil,
              model.spaceProjects.count >= 2 else {
            throw DesignToolError("Design integration checks require two isolated fixture projects.")
        }
        let first = model.spaceProjects[0], second = model.spaceProjects[1]
        model.openProject(first, tab: .design)
        guard let caller = model.selectedSessionID else { throw DesignToolError("Fixture chat missing") }
        let editor = model.design(for: first), other = model.design(for: second)
        let original = editor.document, otherOriginal = other.document
        guard let id = original.nodes.first(where: { !$0.isLocked })?.id else { throw DesignToolError("Editable fixture shape missing") }
        let staleRevision = try DesignTools.revision(of: original)
        editor.edit { $0.move([id], by: CGSize(width: 35, height: 0)) }
        guard model.project(id: first.id)?.design == editor.document else { throw DesignToolError("Manual edits were not saved synchronously") }
        let rejected = await model.performAgentTool(["name": "project_publish_design", "arguments": ["baseRevision": .string(staleRevision), "design": "{\"nodes\":[]}"]], callerID: caller, projectID: first.id)
        guard rejected["isError"]?.bool == true else { throw DesignToolError("A stale publish overwrote manual edits") }

        model.openProject(second, tab: .design)
        guard other.document == otherOriginal else { throw DesignToolError("Edits leaked into another project") }
        model.openProject(first, tab: .design)
        guard model.design(for: first) === editor, editor.canUndo else { throw DesignToolError("Tab navigation discarded undo history") }
        editor.undo()
        guard editor.document == original else { throw DesignToolError("Undo did not restore the previous document") }

        let read = await model.performAgentTool(["name": "project_get_design"], callerID: caller, projectID: first.id)
        let snapshot = try JSONValue(parsing: Data((read["content"]?[0]?["text"]?.string ?? "").utf8))
        guard var payload = snapshot["document"]?.object else { throw DesignToolError("Design snapshot missing") }
        payload["title"] = "Updated from chat"
        let published = await model.performAgentTool(["name": "project_publish_design", "arguments": ["baseRevision": snapshot["baseRevision"] ?? .null,
            "design": .string(String(decoding: try JSONValue.object(payload).serialized(), as: UTF8.self))]], callerID: caller, projectID: first.id)
        guard published["isError"]?.bool != true, editor.document.title == "Updated from chat" else { throw DesignToolError("Chat and the visible canvas diverged") }
        editor.undo()
        guard editor.document == original else { throw DesignToolError("Chat publication could not be undone") }
        editor.redo()
        guard editor.document.title == "Updated from chat" else { throw DesignToolError("Chat publication could not be redone") }
        let denied = await model.performAgentTool(["name": "project_get_design"], callerID: caller, projectID: second.id)
        guard denied["isError"]?.bool == true else { throw DesignToolError("A chat accessed another project's canvas") }

        model.openProject(second, tab: .conversation)
        model.openDesign(for: first.id)
        guard model.selectedProject?.id == first.id, model.projectTabs[first.id] == .design else { throw DesignToolError("Open Design used the wrong project") }
        guard await model.save() else { throw DesignToolError("The fixture did not save") }
        let saved = try await model.store.loadWorkspace()
        guard saved.projects.first(where: { $0.id == first.id })?.design == editor.document,
              saved.projects.first(where: { $0.id == second.id })?.design == otherOriginal else { throw DesignToolError("Stored canvases differ from the editors") }
    }
}
#endif
