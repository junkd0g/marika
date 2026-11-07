import Foundation
import Testing
@testable import MarikaCore

struct SpeedSettingsTests {
    @Test func catalogSpeedTiersKeepTheirNamesAndNormalizeWireAliases() throws {
        let model: JSONValue = ["model": "test", "displayName": "Test", "isDefault": true,
            "defaultServiceTier": "priority", "supportedReasoningEfforts": [["reasoningEffort": "high"]],
            "serviceTiers": [["id": "default", "name": "Standard", "description": "Normal speed"],
                             ["id": "fast", "name": "Fast", "description": "Faster responses"],
                             ["id": "ultrafast", "name": "Ultrafast", "description": "Fastest responses"]]]
        let option = try #require(CodexCLI.option(model))
        #expect(option.speedOptions.map(\.id) == ["default", "priority", "ultrafast"])
        #expect(option.speedOptions.map(\.name) == ["Standard", "Fast", "Ultrafast"])
        #expect(option.speedOptions[1].detail == "Faster responses")
        #expect(option.defaultServiceTier == "priority")
        #expect(option.efforts == ["high"], "Speed and reasoning effort are independent")
    }

    @Test func legacyCatalogsUseAdvertisedSpeedsWithoutInventingTiers() throws {
        let legacy: JSONValue = ["model": "legacy", "additionalSpeedTiers": ["fast", "ultrafast"]]
        #expect(try #require(CodexCLI.option(legacy)).speedOptions.map(\.id) == ["default", "priority", "ultrafast"])
        #expect(try #require(CodexCLI.option(["model": "standard-only"])).speedOptions == [.standard])
        #expect(CodexCLI.option(["model": "hidden", "hidden": true]) == nil)
    }

    @Test func oldSettingsAndModelsDecodeWithoutSpeedMetadata() throws {
        let settings = try JSONDecoder().decode(AgentSettings.self, from: Data(#"{"model":"old-model","effort":"high","mode":"ask"}"#.utf8))
        #expect(settings.serviceTier == nil && settings.effort == "high")
        let model = try JSONDecoder().decode(ModelOption.self, from: Data(#"{"id":"old-model","name":"Old model","detail":"","efforts":["high"],"isDefault":true}"#.utf8))
        #expect(model.speedOptions == [.standard])
    }

    @MainActor @Test func speedRoundTripsIndependentlyOfEffortAndIsInheritedByCodexChildren() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(path: root.path)
        var session = SessionMeta(projectID: project.id, agent: .codex)
        session.settings = AgentSettings(model: "test", effort: "high", serviceTier: "ultrafast")
        let store = Store(root: root)
        try await store.save(Workspace(projects: [project], sessions: [session]))
        let loaded = try #require(try await store.loadWorkspace().sessions.first)
        #expect(loaded.settings == session.settings)
        #expect(loaded.serviceTier == "ultrafast" && loaded.effort == "high")
        #expect(AgentTaskPolicy.childSettings(agent: .codex, parent: loaded).serviceTier == "ultrafast")
        #expect(AgentTaskPolicy.childSettings(agent: .claude, parent: loaded).serviceTier == nil)
        let controller = SessionController(meta: loaded) { _ in IdleAgent() }
        var standard = loaded.settings
        standard.serviceTier = "default"
        controller.update(settings: standard)
        #expect(controller.meta.serviceTier == "default" && controller.meta.effort == "high")
    }
}
