#if DEBUG
import Foundation
import MarikaCore

@MainActor enum DebugDesignImportChecks {
    static func prepare(_ model: AppModel, response: String, delay: Double) throws {
        guard DebugFixtureSettings.value("MARIKA_DATA") != nil, let project = model.selectedProject ?? model.spaceProjects.first else {
            throw DesignToolError("Import checks require an isolated project.")
        }
        model.agentFactoryOverride = { meta in
            guard meta.mode == .plan, let importID = meta.agentTask?.designImportID, meta.agentTask?.workspace == nil,
                  FileManager.default.fileExists(atPath: DesignImportSources.workingDirectory(for: importID).appendingPathComponent("App.tsx").path) else {
                throw DesignToolError("Import did not start a dedicated read-only analysis.")
            }
            return ImportAgent(response: response, delay: delay)
        }
        model.openProject(project, tab: .design)
        let editor = model.design(for: project)
        if editor.document.nodes.isEmpty {
            editor.edit { doc in
                let id = doc.add(.rectangle, in: CGRect(x: 0, y: 0, width: 100, height: 80))
                doc.update([id]) { $0.name = "Manual artwork"; $0.description = "Keep this unchanged"; $0.isLocked = true }
            }
        }
    }

    static func wait(_ model: AppModel, status: String) async throws {
        for _ in 0..<300 {
            if model.selectedProject?.designImport?.status.rawValue == status { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw DesignToolError("Import did not reach \(status): \(model.selectedProject?.designImport?.error ?? "no error")")
    }

    static func check(_ model: AppModel, phase: String) async throws {
        guard let project = model.selectedProject, let run = project.designImport else { throw DesignToolError("Missing import fixture") }
        let editor = model.design(for: project)
        guard let manual = editor.document.nodes.first, manual.name == "Manual artwork", manual.description == "Keep this unchanged", manual.isLocked else {
            throw DesignToolError("Import changed manual artwork")
        }
        switch phase {
        case "preview":
            guard run.status == .ready, run.proposal != nil, editor.document.nodes.count == 1 else { throw DesignToolError("Draft was not staged separately") }
            guard Set(run.files.map(\.framework)).isSuperset(of: ["SwiftUI", "Kotlin / Compose", "HTML", "React", "Vue", "Styles"]),
                  model.activeCheckpoints[run.sessionID] == nil else { throw DesignToolError("Source detection or read-only lifecycle failed") }
            let denied = await model.performAgentTool(["name": "project_publish_design"], callerID: run.sessionID, projectID: project.id)
            guard denied["isError"]?.bool == true else { throw DesignToolError("Import agent could publish directly") }
        case "applied":
            guard run.status == .applied, run.proposal == nil, editor.document.nodes.count > 3,
                  editor.document.nodes.contains(where: { $0.links?.first?.target == "App.tsx" }) else { throw DesignToolError("Draft was not added with source links") }
            let imported = editor.document
            editor.undo()
            guard editor.document.nodes == [manual] else { throw DesignToolError("Import was not one undo step") }
            editor.redo()
            guard editor.document == imported, project.designVersions?.isEmpty == false else { throw DesignToolError("Import redo or saved version failed") }
        case "failed":
            guard run.status == .failed, run.error != nil else { throw DesignToolError("Invalid output was accepted") }
        case "cancelled":
            guard run.status == .cancelled else { throw DesignToolError("Cancelled import changed state") }
        default: throw DesignToolError("Unknown import check")
        }
        guard await model.save() else { throw DesignToolError("Import fixture did not save") }
    }

    private actor ImportAgent: AgentSession {
        nonisolated let events: AsyncStream<AgentEvent>
        private let sink: AsyncStream<AgentEvent>.Continuation
        private let response: String
        private let delay: Double
        private var task: Task<Void, Never>?
        private var active = false
        init(response: String, delay: Double) {
            let stream = AsyncStream<AgentEvent>.makeStream()
            events = stream.stream; sink = stream.continuation; self.response = response; self.delay = delay
        }
        func send(_ input: UserInput) async throws {
            guard input.text.contains("BEGIN UNTRUSTED SOURCE EXCERPTS"), input.text.contains("Main screens") else {
                throw DesignToolError("Missing source or import instructions")
            }
            active = true
            sink.yield(.conversationStarted(id: UUID().uuidString, model: "fixture-import"))
            sink.yield(.activity("Extracting screens and shared styles"))
            sink.yield(.textFinished(id: UUID().uuidString, text: "I am inspecting the selected UI files.", parentToolID: nil))
            task = Task {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                sink.yield(.textFinished(id: UUID().uuidString, text: response, parentToolID: nil))
                sink.yield(.turnFinished(TurnSummary(outcome: .completed)))
                sink.yield(.phaseChanged(.idle)); active = false
            }
        }
        func interrupt() async {
            task?.cancel(); active = false
            sink.yield(.turnFinished(TurnSummary(outcome: .interrupted))); sink.yield(.phaseChanged(.idle))
        }
        func hasActiveTurn() async -> Bool { active }
        func answer(requestID: String, decision: ApprovalDecision) async {}
        func update(settings: AgentSettings) async {}
        func shutdown() async { task?.cancel(); active = false; sink.finish() }
    }
}
#endif
