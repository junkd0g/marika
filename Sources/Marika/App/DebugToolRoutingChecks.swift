#if DEBUG
import Foundation
import MarikaCore

@MainActor
enum DebugToolRoutingChecks {
    static func run(_ model: AppModel) async throws {
        guard DebugFixtureSettings.value("MARIKA_DATA") != nil,
              let caller = model.selectedSession, let project = model.project(for: caller),
              let other = model.spaceProjects.first(where: { $0.id != project.id }) else {
            throw DesignToolError("Tool routing checks require two isolated fixture projects.")
        }
        let fixture = Fixture(model: model, caller: caller, project: project)
        try await fixture.authorization(other: other)
        try await fixture.knowledge()
        try await fixture.publishers()
        try await fixture.childAgents()
    }

    @MainActor private struct Fixture {
        let model: AppModel
        let caller: SessionMeta
        let project: Project

        func call(_ name: String, _ arguments: JSONValue = [:]) async -> JSONValue {
            await model.performAgentTool(["name": .string(name), "arguments": arguments], callerID: caller.id, projectID: project.id)
        }

        func success(_ name: String, _ arguments: JSONValue = [:]) async throws -> String {
            let result = await call(name, arguments)
            let text = result["content"]?[0]?["text"]?.string ?? ""
            try expect(result["isError"]?.bool != true, "\(name): \(text)")
            return text
        }

        func expect(_ condition: Bool, _ message: String) throws {
            if !condition { throw DesignToolError("Tool routing: " + message) }
        }

        func authorization(other: Project) async throws {
            let crossProject = await model.performAgentTool(["name": "project_publish_api"], callerID: caller.id, projectID: other.id)
            try expect(crossProject["isError"]?.bool == true && model.project(id: other.id)?.apiCollection == nil, "cross-project write was allowed")
            let missingCaller = await model.performAgentTool(["name": "project_get_design"], callerID: UUID(), projectID: project.id)
            try expect(missingCaller["isError"]?.bool == true, "missing caller was allowed")
            for (name, message) in [("unknown_tool", "Unknown agent tool."), ("project_publish_comparison", "assigned comparison ID"),
                                    ("project_publish_research", "assigned Research run ID"), ("project_publish_scan_review", "your own scan ID")] {
                let result = await call(name)
                try expect(result["isError"]?.bool == true && result["content"]?[0]?["text"]?.string?.contains(message) == true, "wrong rejection for \(name)")
            }
        }

        func knowledge() async throws {
            _ = try await success("project_propose_knowledge", ["proposal": #"{"entry":{"title":"Routing decision","kind":"decision","content":"Keep the needle decision"},"reason":"Fixture proposal"}"#])
            var knowledge = model.project(id: project.id)?.knowledge ?? ProjectKnowledge()
            try expect(knowledge.entries.isEmpty && knowledge.proposals.count == 1, "proposal bypassed review")
            guard let proposal = knowledge.proposals.first else { throw DesignToolError("Missing fixture proposal") }
            try knowledge.approve(proposal.id)
            model.updateProject(project.id) { $0.knowledge = knowledge }
            guard let entry = knowledge.entries.first else { throw DesignToolError("Missing approved fixture entry") }
            let read = try await success("project_read_knowledge", ["id": .string(entry.id.uuidString), "revision": .int(1)])
            let search = try await success("project_search_knowledge", ["query": "needle"])
            try expect(read.contains("Keep the needle decision") && search.contains(entry.id.uuidString), "knowledge read/search lost the approved revision")
        }

        func publishers() async throws {
            for path in ["/first", "/second"] {
                let collection: JSONValue = ["baseURL": "http://127.0.0.1:3000", "endpoints": [["name": .string(path), "method": "GET", "path": .string(path), "source": "README.md"]]]
                _ = try await success("project_publish_api", ["collection": .string(String(decoding: try collection.serialized(), as: UTF8.self))])
            }
            try expect(model.project(id: project.id)?.apiCollection?.endpoints.map(\.path) == ["/first", "/second"], "same-publisher API merge lost a request")
            _ = try await success("project_publish_artifact", ["kind": "Plan", "title": "Fixture plan", "body": "Review routing behavior."])
            _ = try await success("project_publish_deliverable", ["deliverable": #"{"kind":"report","title":"Fixture report","body":"Routing evidence"}"#])
            try expect(model.project(id: project.id)?.artifacts?.count == 2, "artifact or deliverable was not stored")
            _ = try await success("project_scan_stats")
            guard let scan = model.project(id: project.id)?.scans?.last else { throw DesignToolError("Missing fixture scan") }
            _ = try await success("project_publish_scan_review", ["scanID": .string(scan.id.uuidString), "review": #"{"summary":"Reviewed fixture","inspectedFiles":["README.md"],"findings":[]}"#])
            try expect(model.project(id: project.id)?.scans?.last?.review?.summary == "Reviewed fixture", "scan review was not stored")
        }

        func childAgents() async throws {
            let list = try await success("agent_list")
            try expect(try JSONValue(parsing: Data(list.utf8)).array?.isEmpty == true, "unexpected child agent")
            for (name, args, message) in [("agent_spawn", JSONValue.object(["agent": "invalid"]), "Choose claude or codex."),
                                          ("agent_wait", JSONValue.object(["ids": []]), "one to four child agent IDs"),
                                          ("agent_status", JSONValue.object(["id": .string(caller.id.uuidString)]), "only access child agents"),
                                          ("agent_send", JSONValue.object(["id": .string(caller.id.uuidString)]), "only access child agents"),
                                          ("agent_stop", JSONValue.object(["id": .string(caller.id.uuidString)]), "only access child agents")] {
                let result = await call(name, args)
                try expect(result["isError"]?.bool == true && result["content"]?[0]?["text"]?.string?.contains(message) == true, "wrong child-agent rejection for \(name)")
            }
        }
    }
}
#endif
