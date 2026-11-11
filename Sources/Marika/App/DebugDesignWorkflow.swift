#if DEBUG
import AppKit
import MarikaCore

@MainActor
enum DebugDesignWorkflow {
    private static var projectID: UUID?
    private static var saved: DesignDocument?
    private static var changed: DesignDocument?
    private static var elementID: UUID?
    private static var ticketIDs: Set<UUID> = []

    private static func canvas(_ model: AppModel) throws -> DesignCanvasModel {
        guard DebugFixtureSettings.value("MARIKA_DATA") != nil,
              let project = projectID.flatMap({ model.project(id: $0) }) ?? model.selectedProject ?? model.spaceProjects.first else {
            throw DesignToolError("Workflow checks require an isolated project")
        }
        projectID = project.id; model.openProject(project, tab: .design)
        guard let canvas = model.designCanvases[project.id] else { throw DesignToolError("Canvas missing") }
        return canvas
    }

    static func prepare(_ model: AppModel) throws {
        let canvas = try canvas(model)
        canvas.edit {
            $0 = DesignDocument()
            let id = $0.add(.text, in: CGRect(x: 0, y: 0, width: 260, height: 40))
            $0.update([id]) { $0.name = "Existing notes"; $0.text = "Keep existing notes" }
        }
        canvas.selection = []; canvas.showsTemplates = true
    }

    static func check(_ model: AppModel) async throws {
        let canvas = try canvas(model)
        guard canvas.doc.nodes.count == 10, canvas.doc.nodes.first?.text == "Keep existing notes",
              canvas.doc.connections?.count == 6 else { throw DesignToolError("Template button did not preserve the existing canvas") }
        let inserted = canvas.doc
        canvas.editor.undo()
        guard canvas.doc.nodes.count == 1 else { throw DesignToolError("Template was not one undo step") }
        canvas.editor.redo()
        guard canvas.doc == inserted else { throw DesignToolError("Redo changed the template") }

        let edge = canvas.doc.connections![0], start = edge.labelPoint(in: canvas.doc.nodes)!
        let route = edge.route(in: canvas.doc.nodes)!, end = DesignConnection.point(on: route, fraction: 0.8)
        canvas.selection = []; canvas.selectedConnection = nil
        canvas.pointerDown(DesignPointer(location: canvas.toScreen(start)))
        canvas.pointerDragged(DesignPointer(location: canvas.toScreen(end)))
        canvas.pointerUp(DesignPointer(location: canvas.toScreen(end)))
        guard abs((canvas.doc.connections?.first?.labelFraction ?? 0) - 0.8) < 0.01 else { throw DesignToolError("Dragging a connection label did not move it") }
        canvas.editor.undo()
        guard canvas.doc.connections?.first?.labelFraction == 0.5 else { throw DesignToolError("Label drag did not undo") }

        let api = canvas.doc.nodes.first { $0.component == .api }!
        elementID = api.id
        let file = DesignSourceLink(kind: .file, target: "README.md", line: 1)
        let symbol = DesignSourceLink(kind: .file, target: "README.md")
        let collection = try JSONDecoder().decode(APICollection.self, from: Data(#"{"baseURL":"http://127.0.0.1:9","endpoints":[{"name":"Health","method":"GET","path":"/health","source":"README.md","line":1}]}"#.utf8))
        let endpoint = collection.endpoints[0]
        model.updateProject(canvas.projectID) { $0.apiCollection = collection }
        let request = DesignSourceLink(kind: .endpoint, target: endpoint.id)
        canvas.edit { $0.update([api.id]) { $0.links = [file, symbol, request]; $0.description = "Validate requests, call the service, and return a typed response." } }
        try await model.openDesignLink(file, projectID: canvas.projectID)
        try await Task.sleep(for: .milliseconds(300))
        guard model.projectTabs[canvas.projectID] == .code, model.editors[canvas.projectID]?.selectedDocument?.name == "README.md" else {
            throw DesignToolError("Source link did not open the code editor: tab=\(String(describing: model.projectTabs[canvas.projectID])) file=\(model.editors[canvas.projectID]?.selectedDocument?.name ?? "none")")
        }
        try await model.openDesignLink(symbol, projectID: canvas.projectID)
        try await model.openDesignLink(request, projectID: canvas.projectID)
        guard model.projectTabs[canvas.projectID] == .api, model.apiWorkspaces[canvas.projectID]?.selectedRequestID == endpoint.id else {
            throw DesignToolError("Endpoint link did not select the API request")
        }
        let documentation = DesignSourceLink(kind: .documentation, target: "http://127.0.0.1:9/guide")
        try await model.openDesignLink(documentation, projectID: canvas.projectID)
        guard model.projectTabs[canvas.projectID] == .browser else { throw DesignToolError("Documentation link did not open Browser") }
        do { try await model.openDesignLink(DesignSourceLink(kind: .file, target: "../outside"), projectID: canvas.projectID); throw DesignToolError("Unsafe source path opened") }
        catch let error as DesignToolError where error.message == "Unsafe source path opened" { throw error }
        catch { }
        model.openDesign(for: canvas.projectID)
        canvas.selection = []; let before = canvas.doc
        canvas.tidy(.horizontal); canvas.editor.undo()
        guard canvas.doc == before else { throw DesignToolError("Tidy layout did not undo") }
        canvas.editor.redo(); canvas.fit()
        ticketIDs = Set(model.workspace.spaces.flatMap(\.tickets).map(\.id))
        canvas.selection = [api.id]; canvas.prepareTicket()
        canvas.ticketDraft?.title = "Implement API request handling"
        canvas.ticketDraft?.acceptance = "Reject invalid requests with a useful error.\nReturn the documented response for valid requests.\nAdd tests for both paths."
    }

    static func ticket(_ model: AppModel) async throws {
        let canvas = try canvas(model)
        guard let ticket = model.workspace.spaces.flatMap(\.tickets).first(where: { !ticketIDs.contains($0.id) }),
              ticket.designSource?.elementIDs == [elementID!], ticket.work == nil, ticket.status == .todo else {
            throw DesignToolError("Reviewed ticket was not created safely")
        }
        let context = try model.ticketLaunchDraft(ticket.id)
        guard context.prompt.contains("README.md"), context.prompt.contains("Validate requests"), context.prompt.contains("Reject invalid requests") else {
            throw DesignToolError("Implementation launch is missing design context")
        }
        let controller = try await model.launchAgent(in: model.project(id: canvas.projectID)!, agent: .codex,
                                                     settings: AgentSettings(), prompt: context.prompt, isolated: false, ticketLaunch: context)
        guard controller.meta.agentTask?.ticketID == ticket.id,
              controller.meta.agentTask?.prompt.contains("Validate requests") == true else {
            throw DesignToolError("The implementation agent did not receive its linked design ticket")
        }
        model.openDesign(for: canvas.projectID)
        guard canvas.implementationBadges.contains(where: { $0.ticket == ticket.id && $0.status == .inProgress }) else {
            throw DesignToolError("Ticket status was not reflected on the diagram")
        }
        try model.saveDesignVersion(projectID: canvas.projectID, name: "Reviewed service architecture")
        saved = canvas.doc
        canvas.edit {
            $0.update([elementID!]) { $0.text = "API v2"; $0.fill = DesignColor(0.9, 0.85, 1) }
            $0.title = "Proposed next revision"
            let id = $0.addComponent(.storage, centeredAt: CGPoint(x: 200, y: 650))
            if let edge = $0.connect(elementID!, id, label: "Archive") { $0.updateConnection(edge) { $0.style = .data } }
        }
        changed = canvas.doc
        canvas.showsHistory = true
    }

    static func finish(_ model: AppModel, directory: String) async throws {
        let canvas = try canvas(model)
        guard canvas.doc == saved else { throw DesignToolError("Restore button did not restore the saved version") }
        canvas.editor.undo()
        guard canvas.doc == changed else { throw DesignToolError("Version restore was not undoable") }
        canvas.editor.redo(); canvas.showsHistory = false
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let svg = try DesignSVG.render(canvas.doc)
        guard XMLParser(data: Data(svg.utf8)).parse(), svg.contains("<polyline"), svg.contains("<text"), svg.contains("arrow-event") else {
            throw DesignToolError("SVG is invalid or lost text, shapes, or connections")
        }
        try svg.write(to: folder.appendingPathComponent("architecture.svg"), atomically: true, encoding: .utf8)
        var escaped = DesignDocument()
        escaped.nodes = [DesignNode(kind: .rectangle, name: "<&\"", x: 0, y: 0, width: 220, height: 100)]
        guard XMLParser(data: Data(try DesignSVG.render(escaped).utf8)).parse() else { throw DesignToolError("SVG text was not escaped") }
        canvas.selection = [elementID!]; canvas.fit()
        guard await model.save() else { throw DesignToolError("Workflow failed to save") }
    }
}
#endif
