import Foundation
import Testing
@testable import MarikaCore

struct ResearchAndTaskTests {
    private var report: ResearchReport {
        ResearchReport(answer: "Use the documented API [S1](https://example.test/docs).",
            sources: [ResearchSource(id: "S1", title: "Official docs", url: "https://example.test/docs", excerpt: "The API accepts a timeout.")],
            findings: [ResearchFinding(id: "F1", title: "Set a timeout", detail: "The project's request has no timeout.", sourceIDs: ["S1"], nextAction: "Inspect the request and configure a bounded timeout.")])
    }
    private func json(_ report: ResearchReport) throws -> String { String(decoding: try JSONEncoder().encode(report), as: UTF8.self) }

    @Test func researchPublicationIsOwnedAtomicAndKeepsTaskLinks() throws {
        let owner = UUID(), task = UUID()
        var run = ResearchRun(sessionID: owner, question: "Which API?", focus: .documentation)
        run.implementationTasks = ["F1": task]
        #expect(throws: AgentError.self) { try run.publish(json(report), callerID: UUID()) }
        #expect(run.report == nil)
        try run.publish(json(report), callerID: owner)
        let saved = run
        #expect(throws: (any Error).self) { try run.publish("{}", callerID: owner) }
        #expect(run == saved && run.implementationTasks?["F1"] == task)
        #expect(try JSONDecoder().decode(ResearchRun.self, from: JSONEncoder().encode(run)) == saved)
    }

    @Test func researchRejectsUnsafeLinksDuplicateIDsAndDanglingEvidence() throws {
        for url in ["javascript:alert(1)", "file:///tmp/local", "https://user:secret@example.test", "https:", "https://example.test/\nsecret"] {
            var value = report; value.sources[0].url = url
            #expect(throws: AgentError.self) { try value.validate() }
        }
        var value = report; value.sources.append(value.sources[0])
        #expect(throws: AgentError.self) { try value.validate() }
        value = report; value.findings[0].sourceIDs = ["missing"]
        #expect(throws: AgentError.self) { try value.validate() }
        value = report; value.findings[0].sourceIDs = ["S1", "S1"]
        #expect(throws: AgentError.self) { try value.validate() }
        value = report; value.sources[0].excerpt = " "
        #expect(throws: AgentError.self) { try value.validate() }
        value = report; value.findings = []
        try value.validate()
        #expect(throws: AgentError.self) { try ResearchReport.parse(String(repeating: "x", count: 150_001)) }
    }

    @Test func implementationHandoffContainsSelectedEvidenceAndFitsTaskLimit() throws {
        var value = report
        value.sources.append(ResearchSource(id: "S2", title: "Unrelated", url: "https://example.test/other", excerpt: "Do not include this unrelated source."))
        let prompt = value.implementationPrompt(for: value.findings[0], question: "Choose an API")
        #expect(prompt.contains("https://example.test/docs") && prompt.contains("bounded timeout"))
        #expect(!prompt.contains("Unrelated") && prompt.contains("untrusted reference"))
        value.sources = (0..<40).map { ResearchSource(id: "S\($0)", title: "Docs", url: "https://example.test/\($0)", excerpt: String(repeating: "e", count: 3000)) }
        value.findings[0].sourceIDs = value.sources.map(\.id)
        value.findings[0].detail = String(repeating: "d", count: 6000)
        value.findings[0].nextAction = String(repeating: "a", count: 6000)
        #expect(value.implementationPrompt(for: value.findings[0], question: String(repeating: "q", count: 6000)).count < 32_000)
    }

    @Test func researchAndTaskMetadataRoundTripAndOlderWorkspacesStillLoad() throws {
        var project = Project(path: "/tmp/research")
        var meta = SessionMeta(projectID: project.id, agent: .codex, agentTask: AgentTask(prompt: "Inspect"))
        meta.taskPlan = [TodoItem(text: "Inspect sources", status: .inProgress)]
        meta.taskVerification = TaskVerificationRecord(command: "swift test", output: "Passed", succeeded: true)
        project.research = [ResearchRun(sessionID: meta.id, question: "Compare libraries", focus: .libraries)]
        var layout = ProjectLayout(); layout.openTab(.research); project.layout = layout
        let workspace = Workspace(projects: [project], sessions: [meta])
        #expect(try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace)) == workspace)
        var fields = try #require(JSONValue(parsing: JSONEncoder().encode(meta)).object)
        fields["taskPlan"] = nil; fields["taskVerification"] = nil
        let old = try JSONDecoder().decode(SessionMeta.self, from: JSONValue.object(fields).serialized())
        #expect(old.taskPlan == nil && old.taskVerification == nil)
        #expect(Set(ProjectPanel.allCases.map(\.shortcut)).count == ProjectPanel.allCases.count)
    }

    @MainActor @Test func taskPlanAndVerificationSurviveControllerReload() throws {
        let meta = SessionMeta(projectID: UUID(), agent: .claude)
        let controller = SessionController(meta: meta) { _ in IdleAgent() }
        var saves = 0; controller.onChange = { _ in saves += 1 }
        controller.apply(.todosUpdated([TodoItem(text: "Inspect", status: .completed)]))
        controller.recordVerification(TaskVerificationRecord(command: "fixture test", output: "ok", succeeded: true))
        let reloaded = SessionController(meta: controller.meta) { _ in IdleAgent() }
        #expect(reloaded.todos == controller.todos && reloaded.meta.taskVerification?.succeeded == true && saves >= 2)
    }

    @Test func taskOverviewUsesSuccessfulDiffsAndCurrentBlockersOnly() {
        let meta = SessionMeta(projectID: UUID(), agent: .codex)
        func item(_ content: TranscriptItem.Content) -> TranscriptItem { TranscriptItem(id: UUID().uuidString, content: content) }
        let items: [TranscriptItem] = [
            item(.notice(Notice(level: .error, text: "Old failure"))),
            item(.tool(ToolCall(id: "denied", name: "edit", kind: .edit, title: "Edit", detail: "", status: .denied, diff: [DiffFile(path: "denied.swift")]))),
            item(.tool(ToolCall(id: "done", name: "edit", kind: .edit, title: "Edit", detail: "", status: .succeeded, diff: [DiffFile(path: "old.swift", movedTo: "new.swift")]))),
            TranscriptItem(id: "nested", parentToolID: "child", content: .tool(ToolCall(id: "child-edit", name: "edit", kind: .edit, title: "Child edit", detail: "", status: .succeeded, diff: [DiffFile(path: "child-worktree.swift")]))),
            item(.user(text: "Try again", images: [])), item(.turnEnd(TurnSummary(outcome: .completed)))
        ]
        let overview = AgentTaskOverview(meta: meta, items: items, phase: .idle)
        #expect(overview.changedFiles == ["new.swift"] && overview.blockers.isEmpty && overview.activeStep == nil)
        let waiting = AgentTaskOverview(meta: meta, items: items, phase: .waitingForUser, approval: ApprovalRequest(id: "a", title: "Run tests"), activity: "Inspecting")
        #expect(waiting.blockers == ["Approval needed: Run tests"] && waiting.activeStep == "Inspecting")
        #expect(!AgentTaskOverview(meta: meta, items: [], phase: .waitingForUser).blockers.isEmpty)
        var archived = meta
        archived.agentTask = AgentTask(prompt: "Archived task")
        archived.agentTask?.workspace = AgentWorkspace(rootPath: "/tmp/root", workingPath: "/tmp/work", branch: "task", baseCommit: "abc")
        archived.agentTask?.workspace?.status = .discarded
        #expect(AgentTaskOverview(meta: archived, items: [], phase: .idle).blockers.first?.contains("discarded") == true)
    }

    @Test func catalogSearchAndConnectionMatchingRespectActualEndpoints() throws {
        for entry in ConnectionCatalogEntry.entries {
            #expect(entry.endpoint.hasPrefix("https://") && entry.documentation.hasPrefix("https://"))
            let config = try MCPConfigurationEditor.save(entry.server, in: #"{"mcpServers":{}}"#)
            var server = try #require(MCPConfigurationEditor.servers(in: config).first)
            server.name = "renamed"
            #expect(entry.configuredServer(in: [server]) == server)
            #expect(entry.configuredServer(in: [MCPServerConfiguration(name: entry.id, configuration: ["url": "https://evil.test/mcp"])]) == nil)
        }
        #expect(ConnectionCatalogEntry.entries.filter { $0.matches("library documentation") }.map(\.id) == ["context7"])
        #expect(ConnectionCatalogEntry.entries.filter { $0.matches(" LINEAR ") }.map(\.id) == ["linear"])
    }

    @Test func retentionPreservesOlderRunningResearchUntilItCanPublish() {
        let active = ResearchRun(sessionID: UUID(), question: "Slow research", focus: .competitors)
        let runs = [active] + (0..<45).map { ResearchRun(sessionID: UUID(), question: "Question \($0)", focus: .libraries) }
        #expect(ResearchRun.retained(runs, active: []).count == 40)
        let retained = ResearchRun.retained(runs, active: [active.sessionID])
        #expect(retained.count == 41 && retained.first?.id == active.id && retained.last?.id == runs.last?.id)
    }
}
