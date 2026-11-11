import Foundation
import Testing
@testable import MarikaCore

struct DesignWorkflowTests {
    private func simple() -> DesignDocument {
        var doc = DesignDocument()
        let a = doc.add(.rectangle, in: CGRect(x: 0, y: 0, width: 100, height: 80))
        let b = doc.add(.rectangle, in: CGRect(x: 400, y: 0, width: 100, height: 80))
        doc.connect(a, b, label: "Request")
        return doc
    }

    @Test func portsAndObstacleRoutingFollowBoxes() throws {
        var doc = simple()
        let obstacle = doc.add(.rectangle, in: CGRect(x: 180, y: -40, width: 120, height: 160))
        let edge = try #require(doc.connections?.first)
        let route = try #require(edge.route(in: doc.nodes))
        #expect(route.first == CGPoint(x: 100, y: 40))
        #expect(route.last == CGPoint(x: 400, y: 40))
        let box = try #require(doc.node(obstacle)).bounds
        for (a, b) in zip(route, route.dropFirst()) {
            #expect(a.x == b.x || a.y == b.y)
            for i in 1..<100 {
                let p = CGPoint(x: a.x + (b.x - a.x) * Double(i) / 100, y: a.y + (b.y - a.y) * Double(i) / 100)
                #expect(!box.contains(p))
            }
        }
        doc.updateConnection(edge.id) { $0.fromPort = .top; $0.toPort = .bottom; $0.avoidsObstacles = false }
        let explicit = try #require(doc.connections?.first?.route(in: doc.nodes))
        #expect(explicit.first == CGPoint(x: 50, y: 0) && explicit.last == CGPoint(x: 450, y: 80))
        #expect(explicit[1].y < 0 && explicit[explicit.count - 2].y > 80)
        doc.move([doc.nodes[0].id], by: CGSize(width: 50, height: 20))
        #expect(doc.connections?.first?.route(in: doc.nodes)?.first == CGPoint(x: 100, y: 20))
    }

    @Test func labelPositionUsesDistanceAlongTheRoute() {
        let route = [CGPoint.zero, CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 300)]
        #expect(DesignConnection.point(on: route, fraction: 0.5) == CGPoint(x: 100, y: 100))
        #expect(DesignConnection.fraction(on: route, nearest: CGPoint(x: 120, y: 200)) == 0.75)
        #expect(DesignConnection.fraction(on: route, nearest: .zero) == 0.1)
        #expect(DesignConnection.fraction(on: [.zero], nearest: .zero) == 0.5)
        let from = UUID(), to = UUID()
        var edge = DesignConnection(from: from, to: to)
        edge.fromPort = .top; edge.toPort = .right; edge.labelPosition = 0.25
        edge.reverse()
        #expect(edge.from == to && edge.to == from && edge.fromPort == .right && edge.toPort == .top && edge.labelFraction == 0.75)
    }

    @Test func flowAndLinksSurviveAgentRoundTripAndOmittedMetadata() throws {
        var doc = simple()
        let link = DesignSourceLink(kind: .symbol, target: "Sources/Service.swift", line: 12, symbol: "Service.run")
        doc.update([doc.nodes[0].id]) { $0.links = [link] }
        doc.updateConnection(doc.connections![0].id) { $0.style = .event; $0.fromPort = .bottom; $0.toPort = .top; $0.labelPosition = 0.7; $0.avoidsObstacles = false }
        func publish(_ object: [String: JSONValue]) throws -> DesignDocument {
            try DesignTools.publish(["baseRevision": .string(DesignTools.revision(of: doc)), "design": .string(String(decoding: JSONValue.object(object).serialized(), as: UTF8.self))], replacing: doc)
        }
        var object = try #require(DesignTools.snapshot(doc)["document"]?.object)
        #expect(try publish(object) == doc)
        var nodes = try #require(object["nodes"]?.array), node = try #require(nodes[0].object)
        node.removeValue(forKey: "links"); nodes[0] = .object(node); object["nodes"] = .array(nodes)
        var edges = try #require(object["connections"]?.array), edge = try #require(edges[0].object)
        for key in ["style", "fromPort", "toPort", "labelPosition", "avoidsObstacles"] { edge.removeValue(forKey: key) }
        edges[0] = .object(edge); object["connections"] = .array(edges)
        #expect(try publish(object) == doc)
        let reference = try DesignTools.referencePrompt(doc)
        #expect(reference.contains("Sources/Service.swift") && reference.contains("Service.run") && reference.contains("Event; bottom → top"))
    }

    @Test func linkValidationAndOptionalIDs() throws {
        let decoded = try JSONDecoder().decode(DesignSourceLink.self, from: Data(#"{"kind":"file","target":"README.md"}"#.utf8))
        #expect(decoded.isValid)
        for target in ["../secret", "/etc/passwd", "src/../../secret", ""] {
            #expect(!DesignSourceLink(kind: .file, target: target).isValid)
        }
        for target in ["javascript:alert(1)", "file:///tmp/doc", "https://user:password@example.com"] {
            #expect(!DesignSourceLink(kind: .documentation, target: target).isValid)
        }
        #expect(DesignSourceLink(kind: .documentation, target: "https://example.com/docs").isValid)
        #expect(!DesignSourceLink(kind: .file, target: "README.md", line: 0).isValid)
    }

    @Test(arguments: DesignTemplate.allCases) func templatesAreEditableAndAppendWithoutReplacing(_ template: DesignTemplate) throws {
        var doc = simple()
        let original = doc, ids = doc.insertTemplate(template)
        #expect(doc.nodes.filter { !ids.contains($0.id) } == original.nodes)
        #expect(Set((doc.connections ?? []).prefix(original.connections!.count)) == Set(original.connections!))
        #expect(ids.count == template.makeDocument().nodes.count)
        #expect(doc.bounds(of: ids)!.minX >= original.visibleBounds!.maxX + 99)
        let nodes = template.makeDocument().nodes
        #expect(nodes.filter { $0.component != nil }.allSatisfy { $0.description?.hasPrefix("Proposed") == true })
        #expect(Set(doc.nodes.map(\.id)).count == doc.nodes.count)
        #expect(try JSONDecoder().decode(DesignDocument.self, from: JSONEncoder().encode(doc)) == doc)
    }

    @Test func tidyOrdersFlowsAndPreservesCycles() throws {
        var doc = simple()
        doc.nodes[0].x = 300; doc.nodes[0].y = 300; doc.nodes[1].x = 0
        let ids = doc.nodes.map(\.id), connections = doc.connections
        doc.tidyLayout()
        #expect(doc.nodes[0].bounds.maxX < doc.nodes[1].bounds.minX)
        #expect(doc.nodes[0].y == doc.nodes[1].y)
        doc.connect(ids[1], ids[0], label: "response")
        doc.tidyLayout(direction: .vertical)
        #expect(doc.connections?.count == 2 && Set(doc.nodes.map(\.id)) == Set(ids))
        #expect(doc.connections?.first == connections?.first)
        #expect(!doc.nodes[0].bounds.intersects(doc.nodes[1].bounds))
        let once = doc; doc.tidyLayout(direction: .vertical)
        #expect(doc == once)
    }

    @Test func tidyPreservesFrameMembershipAndLockedSubtrees() throws {
        var doc = DesignTemplate.deployment.makeDocument()
        let before = doc.parents
        let locked = try #require(doc.nodes.first { $0.component == .database })
        doc.setLocked(locked.id, true)
        var ancestors: Set<UUID> = [], cursor = before[locked.id]
        while let id = cursor { ancestors.insert(id); cursor = before[id] }
        let fixed = doc.nodes.filter { ancestors.contains($0.id) || $0.id == locked.id }
        doc.tidyLayout()
        #expect(doc.parents == before)
        #expect(doc.nodes.filter { ancestors.contains($0.id) || $0.id == locked.id } == fixed.map { var n = $0; if n.id == locked.id { n.isLocked = true }; return n })
    }

    @Test @MainActor func layoutIsOneUndoStep() {
        var doc = simple(); doc.nodes[0].y = 300
        let editor = DesignWorkspace(document: doc)
        editor.edit { $0.tidyLayout() }
        #expect(editor.document != doc)
        editor.undo(); #expect(editor.document == doc)
        editor.redo(); #expect(editor.document != doc)
    }

    @Test func namedVersionsDiffAndPersistence() throws {
        let old = simple(); var current = old
        current.nodes[0].text = "Changed"; current.nodes.removeLast()
        _ = current.add(.ellipse, in: CGRect(x: 500, y: 0, width: 100, height: 100))
        current.connections = nil; current.title = "Renamed"
        let diff = DesignDifference(before: old, after: current)
        #expect(diff.added.count == 1 && diff.removed.count == 1 && diff.changed == [old.nodes[0].id])
        #expect(diff.connectionsChanged == 1 && diff.titleChanged && !diff.isEmpty)
        #expect(DesignDifference(before: old, after: old).isEmpty)
        var project = Project(path: "/tmp/design-test"); project.design = current
        project.designVersions = [DesignVersion(name: "Before change", document: old)]
        let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(restored.designVersions?.first?.document == old && restored.design == current)
    }

    @Test func reviewedDesignTicketsCarryLatestContextAndRejectMissingElements() throws {
        var project = Project(path: "/tmp/design-test"); project.design = simple()
        let id = project.design!.nodes[0].id
        project.design!.update([id]) { $0.description = "Validate the token before reading data."; $0.links = [DesignSourceLink(kind: .file, target: "Sources/API.swift")] }
        var workspace = Workspace(projects: [project])
        var draft = try DesignTicketDraft(projectID: project.id, document: project.design!, selection: [id])
        draft.title = "Implement token validation"; draft.acceptance = "Reject expired tokens.\nAccept valid tokens."
        let ticket = try workspace.createTicket(from: draft)
        #expect(ticket.title == draft.title && ticket.status == .todo && ticket.work == nil)
        #expect(ticket.body.contains("- [ ] Reject expired tokens."))
        #expect(ticket.designSource?.elementIDs == [id])
        let context = try TicketWorkContext(ticket: ticket, notes: [], design: project.design)
        #expect(context.prompt.contains("Validate the token") && context.prompt.contains("Sources/API.swift"))
        project.design!.update([id]) { $0.description = "Use the refreshed token policy." }
        #expect(try TicketWorkContext(ticket: ticket, notes: [], design: project.design).digest != context.digest)
        project.design!.nodes.removeAll { $0.id == id }
        #expect(throws: TicketWorkError.self) { try TicketWorkContext(ticket: ticket, notes: [], design: project.design) }
        workspace.projects[0] = project
        #expect(throws: TicketWorkError.self) { try workspace.createTicket(from: draft) }
    }
}
