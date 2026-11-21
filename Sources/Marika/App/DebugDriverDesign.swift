#if DEBUG
    import AppKit
    import MarikaCore
    import PDFKit
    import SwiftUI

    extension DebugDriver {
        static func runDesignStep(_ step: JSONValue, _ model: AppModel) async throws -> Bool {
            switch step["op"]?.string {
            case "designImportPrepare":
                try DebugDesignImportChecks.prepare(model, response: step["response"]?.string ?? "", delay: step["delay"]?.double ?? 1)
            case "designImportWait":
                try await DebugDesignImportChecks.wait(model, status: step["status"]?.string ?? "ready", stopOnFailure: step["stopOnFailure"]?.bool == true)
            case "designImportSelective":
                try await DebugDesignImportChecks.selective(model)
            case "designImportApplySelective":
                try await DebugDesignImportChecks.applySelective(model)
            case "designImportCheck":
                try await DebugDesignImportChecks.check(model, phase: step["phase"]?.string ?? "preview")
                log("Design import \(step["phase"]?.string ?? "") passed")
            case "sixDesign":
                try DebugWorkspaceSixChecks.design(model, showSystem: step["system"]?.bool ?? false)
            case "designDescriptionsTest":
                try await DebugDesignChecks.descriptions(model)
                log("Design descriptions passed: persistence, agent context, draft preservation, and no automatic send")
            case "designComponentsPrepare":
                try DebugDesignComponents.prepare(model)
            case "designWorkflowPrepare":
                try DebugDesignWorkflow.prepare(model)
            case "designIntelligenceTest":
                try await DebugDesignIntelligence.run(model)
                log("Design intelligence passed: real declarations, moved symbols, references, health checks, and stale results")
            case "designIntelligenceSelection":
                try DebugDesignIntelligence.selection(model, added: step["added"]?.bool ?? false)
            case "designWorkflowCheck":
                try await DebugDesignWorkflow.check(model)
            case "designWorkflowTicket":
                try await DebugDesignWorkflow.ticket(model)
            case "designWorkflowFinish":
                try await DebugDesignWorkflow.finish(model, directory: step["directory"]?.string ?? "")
                log("Design workflows passed: templates, routed labels, source links, reviewed tickets, status badges, versions, restore, and SVG")
            case "designComponentsCheck":
                try DebugDesignComponents.check(model, directory: step["directory"]?.string ?? "")
                log("Engineering components passed: library insertion, undo, drops, roles, chat context, and rendered icons")
            case "designComponentsCapture":
                try DebugDesignComponents.capture(model, path: step["path"]?.string ?? "")
            case "designCanvasTest":
                let menuPath = try await DebugDesignChecks.canvas(model)
                log("Design canvas passed: drawing, snapping, group resize, rotation, connectors, text, frames, duplication, shortcuts, zoom, and native events"
                    + (menuPath ? "; menu-bar shortcuts checked" : "; menu-bar shortcuts skipped because the window was not key"))
            case "designVisualTest":
                try await DebugDesignVisualChecks.run(model, directory: step["directory"]?.string ?? "")
                log("Design visuals passed: fills, labels, connectors, selection changes, appearance, compact layout, hierarchy and PNG export")
            case "designLayerState":
                guard let project = model.selectedProject, let canvas = model.designCanvases[project.id],
                      canvas.layerRows.count == step["count"]?.int else { throw DriverError("Unexpected visible Design layers") }
                if let names = step["selected"]?.array?.compactMap(\.string) {
                    guard Set(canvas.selectedNodes.map(\.name)) == Set(names) else {
                        throw DriverError("Unexpected Design selection: \(canvas.selectedNodes.map(\.name))")
                    }
                }
                log("Design layer tree state passed")
            case "designSelect":
                try DebugDesignChecks.select(model, names: step["names"]?.array?.compactMap(\.string) ?? [],
                                             connection: step["connection"]?.bool ?? false, tool: step["tool"]?.string,
                                             editing: step["editing"]?.bool ?? false, clear: step["clear"]?.bool ?? false)
                try await pause(0.4)
            case "designExportTest":
                try DebugDesignChecks.render(model, to: step["directory"]?.string ?? "")
                log("Design PNG rendering passed: selected shapes, visible bounds, dimensions, and nonblank pixels")
            case "designIntegrationTest":
                try await DebugDesignChecks.run(model)
                log("Design integration passed: synchronous edits, stale publishing, project isolation, history, navigation, and persistence")
            case "designToolsTest":
                let session = try await current(model)
                guard let project = model.selectedProject, let design = step["design"]?.string else { throw DriverError("Design fixture missing") }
                let read = await model.performAgentTool(["name": "project_get_design"], callerID: session.id, projectID: project.id)
                let snapshot = try JSONValue(parsing: Data((read["content"]?[0]?["text"]?.string ?? "").utf8))
                let revision = snapshot["baseRevision"] ?? .null
                let published = await model.performAgentTool(["name": "project_publish_design", "arguments": ["design": .string(design), "baseRevision": revision]], callerID: session.id, projectID: project.id)
                guard published["isError"]?.bool != true, let document = model.project(id: project.id)?.design,
                      !document.nodes.isEmpty, !(document.connections ?? []).isEmpty else {
                    throw DriverError("Design tool did not publish shapes and connections: \(published)")
                }
                let stale = await model.performAgentTool(["name": "project_publish_design", "arguments": ["design": "{\"nodes\":[]}", "baseRevision": revision]], callerID: session.id, projectID: project.id)
                guard stale["isError"]?.bool == true, model.project(id: project.id)?.design == document else {
                    throw DriverError("Stale Design update changed the canvas")
                }
                let output = published["content"]?[0]?["text"]?.string ?? ""
                session.apply(.tool(ToolCall(id: "design-fixture", name: "mcp__marika_browser__project_publish_design", kind: .mcp,
                    title: "Publish Design", detail: "Architecture diagram", output: output, status: .succeeded)))
                session.apply(.textFinished(id: "design-fixture-reply", text: "The architecture is ready in Design. Open the editable canvas below.", parentToolID: nil))
                await model.save()
                log("Design tools passed: publication, stale-update rejection, and chat result")
            default: return false
            }
            return true
        }
    }
#endif
