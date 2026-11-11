#if DEBUG
import Foundation
import MarikaCore

@MainActor enum DebugDesignIntelligence {
    private static var projectID: UUID?
    private static var sourceID: UUID?

    static func run(_ model: AppModel) async throws {
        guard DebugFixtureSettings.value("MARIKA_DATA") != nil, let project = model.selectedProject ?? model.spaceProjects.first else {
            throw DesignToolError("Intelligence checks require an isolated project")
        }
        projectID = project.id
        try "module example.test/design\n\ngo 1.24\n".write(to: project.url.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        let text = "package design\n// Run is mentioned here, but this is not its definition.\ntype Service struct{}\nfunc (Service) Run() {}\nfunc Call() { Service{}.Run() }\n"
        try text.write(to: project.url.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
        try "Project documentation\n".write(to: project.url.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        model.openProject(project, tab: .design)
        let canvas = model.designCanvases[project.id]!
        let declarations = try await model.designSymbols(projectID: project.id, path: "main.go")
        guard let method = declarations.first(where: { $0.name.contains("Run") }), method.position.line == 3,
              model.projectTabs[project.id] == .design else { throw DesignToolError("Real language-server lookup failed or navigated away from Design") }
        let link = DesignSourceLink(kind: .symbol, target: "main.go", line: 4, symbol: method.identity.name, symbolIdentity: method.identity)
        try ("// Inserted line\n\n" + text).write(to: project.url.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
        try await model.openDesignLink(link, projectID: project.id)
        guard let editor = model.editors[project.id], editor.selectedDocument?.line == 6 else {
            throw DesignToolError("Symbol link used its old line instead of the current declaration")
        }
        try await model.openDesignSymbolReferences(link, projectID: project.id)
        let ide = model.ide(for: project, editor: editor)
        for _ in 0..<150 where ide.results.count < 2 { try await Task.sleep(for: .milliseconds(30)) }
        guard ide.results.count == 2 else { throw DesignToolError("Symbol references included comments or lost a real reference") }
        model.openDesign(for: project.id)
        canvas.edit {
            $0 = DesignDocument(); $0.title = "Design health example"
            let api = $0.addComponent(.api, centeredAt: CGPoint(x: 150, y: 150))
            let database = $0.addComponent(.database, centeredAt: CGPoint(x: 500, y: 150))
            let worker = $0.addComponent(.worker, centeredAt: CGPoint(x: 500, y: 360))
            $0.connect(api, database, label: "Read / write")
            $0.update([api]) { $0.links = [link, DesignSourceLink(kind: .file, target: "removed.go"), DesignSourceLink(kind: .endpoint, target: "GET /removed")] }
            $0.update([database]) { $0.links = [DesignSourceLink(kind: .symbol, target: "main.go", symbol: "DeletedService")] }
            $0.update([worker]) { $0.links = [DesignSourceLink(kind: .symbol, target: "README.md", symbol: "Not a declaration")] }
            sourceID = api
        }
        let original = canvas.doc
        canvas.health.refresh(canvas)
        for _ in 0..<200 where canvas.health.isRunning { try await Task.sleep(for: .milliseconds(30)) }
        let kinds = Set(canvas.health.issues.map(\.kind))
        guard !canvas.health.isRunning, canvas.health.error == nil,
              kinds == [.missingFile, .missingEndpoint, .missingSymbol, .unverified, .disconnected],
              canvas.doc == original, !canvas.health.isStale(canvas) else {
            throw DesignToolError("Health audit failed: " + String(describing: kinds) + " " + (canvas.health.error ?? ""))
        }
        canvas.edit { $0.update([sourceID!]) { $0.description = "Changed after check" } }
        guard canvas.health.isStale(canvas) else { throw DesignToolError("Health results were not marked stale after a design edit") }
        canvas.editor.undo(); canvas.selection = []; canvas.fit(); canvas.showsHealth = true
        guard await model.save() else { throw DesignToolError("Intelligence fixture did not save") }
    }

    static func selection(_ model: AppModel, added: Bool) throws {
        guard let projectID, let canvas = model.designCanvases[projectID], canvas.selection == [sourceID!] else {
            throw DesignToolError("Health panel did not reveal its source element")
        }
        if added {
            guard let links = canvas.doc.node(sourceID!)?.links, links.count == 4, links.last?.symbolIdentity != nil else {
                throw DesignToolError("Symbol picker did not add the selected declaration")
            }
        }
    }
}
#endif
