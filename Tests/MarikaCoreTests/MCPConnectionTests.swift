import Foundation
import Testing
@testable import MarikaCore

@Suite struct MCPConnectionTests {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("marika-mcp-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func config(_ mode: String, root: URL) throws -> JSONValue {
        ["command": "/usr/bin/python3", "args": [.string(try Fixture.url("fake-mcp.py").path), .string(mode), .string(root.appendingPathComponent("requests.jsonl").path)]]
    }
    private func methods(_ root: URL) throws -> [String] {
        try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n")
            .compactMap { try JSONValue(parsing: Data($0.utf8))["method"]?.string }
    }

    @Test func serverEditingPreservesOptionsAndEnvironmentReferences() throws {
        let initial = #"{"metadata":{"version":2},"mcpServers":{"alpha":{"command":"npx","args":["-y","fixture"],"env":{"TOKEN":"${TOKEN}"},"startup_timeout_sec":40}}}"#
        var server = try #require(MCPConfigurationEditor.servers(in: initial).first)
        server.name = "renamed"
        var changed = try MCPConfigurationEditor.save(server, replacing: "alpha", in: initial)
        changed = try MCPConfigurationEditor.enabled(false, name: "renamed", in: changed)
        let parsed = try JSONValue(parsing: Data(changed.utf8))
        #expect(parsed["metadata"]?["version"]?.int == 2)
        #expect(parsed["mcpServers"]?["alpha"] == nil)
        #expect(parsed["mcpServers"]?["renamed"]?["startup_timeout_sec"]?.int == 40)
        #expect(parsed["mcpServers"]?["renamed"]?["env"]?["TOKEN"]?.string == "${TOKEN}")
        #expect(try ProjectMCP.resolved(ProjectMCP.servers(changed), environment: [:]).isEmpty)
        #expect(throws: AgentError.self) { try MCPConfigurationEditor.save(server, in: changed) }
        changed = try MCPConfigurationEditor.enabled(true, name: "renamed", in: changed)
        #expect(try MCPConfigurationEditor.servers(in: changed).first?.enabled == true)
        let removed = try MCPConfigurationEditor.remove("renamed", from: changed)
        #expect(try ProjectMCP.servers(removed).isEmpty)
        #expect(try JSONValue(parsing: Data(removed.utf8))["metadata"]?["version"]?.int == 2)
    }

    @Test func invalidServerSettingsAreRejectedAndURLSummaryHidesCredentials() throws {
        for config: JSONValue in [
            ["command": ""], ["url": "file:///tmp/server"], ["url": "https:"],
            ["command": "npx", "url": "https://example.test/mcp"],
            ["command": "npx", "env": ["TOKEN": 4]], ["url": "https://example.test/mcp", "type": "invalid"]
        ] {
            #expect(throws: AgentError.self) {
                try MCPConfigurationEditor.save(MCPServerConfiguration(name: "fixture", configuration: config), in: "{\"mcpServers\":{}}")
            }
        }
        let remote = MCPServerConfiguration(name: "remote", configuration: ["url": "https://user:password@example.test/mcp?token=secret#secret"])
        #expect(remote.summary == "https://example.test/mcp")
    }

    @Test func stdioProbeInitializesPaginatesAndNeverCallsTools() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        var configuration = try config("stdio", root: root).object!
        configuration["env"] = ["TOKEN": "${FIXTURE_SECRET}", "MCP_EXPECT_TOKEN": "fixture-secret"]
        let report = try await MCPConnectionProbe.check(name: "fixture", configuration: .object(configuration), root: root,
            environment: ProcessInfo.processInfo.environment.merging(["FIXTURE_SECRET": "fixture-secret"]) { _, new in new })
        #expect(report.server == "Marika fixture" && report.tools.map(\.name) == ["read_file", "inspect_schema"])
        #expect(report.resources == 1 && report.prompts == 1)
        #expect(try methods(root) == ["initialize", "notifications/initialized", "tools/list", "tools/list", "resources/list", "prompts/list"])
    }

    @Test(arguments: ["http", "http-auth", "http-sse", "legacy"])
    func remoteProbeSupportsJSONStreamingAndLegacySSE(mode: String) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let server = LineProcess(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [try Fixture.url("fake-mcp.py").path, mode, root.appendingPathComponent("requests.jsonl").path],
            environment: ProcessInfo.processInfo.environment, workingDirectory: root)
        try server.start(); defer { server.terminate(); server.forceKill() }
        var iterator = server.output.makeAsyncIterator()
        guard case .line(let data) = await iterator.next() else { Issue.record("Server did not start"); return }
        let url = String(decoding: data, as: UTF8.self)
        let configuration: JSONValue = ["url": .string(url), "type": .string(mode == "legacy" ? "sse" : "http"), "headers": ["Authorization": "Bearer ${FIXTURE_SECRET}"]]
        let report = try await MCPConnectionProbe.check(name: "fixture", configuration: configuration, root: root,
            environment: ["FIXTURE_SECRET": "fixture-secret"], timeout: 5)
        #expect(report.tools.count == 2 && report.resources == 1 && report.prompts == 1)
        #expect(try methods(root).prefix(2) == ["initialize", "notifications/initialized"])
        #expect(try !methods(root).contains("tools/call"))
        if mode != "legacy" { #expect(try methods(root).last == "DELETE") }
    }

    @Test func aSilentServerTimesOutAndCancellationReturnsPromptly() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try config("silent", root: root)
        let start = Date()
        await #expect(throws: AgentError.self) {
            try await MCPConnectionProbe.check(name: "fixture", configuration: configuration, root: root,
                environment: ProcessInfo.processInfo.environment, timeout: 1)
        }
        #expect(Date().timeIntervalSince(start) < 4)
        let task = Task {
            try await MCPConnectionProbe.check(name: "fixture", configuration: configuration, root: root,
                environment: ProcessInfo.processInfo.environment, timeout: 15)
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled probe returned a result") }
        catch { #expect(error is CancellationError) }
        #expect(Date().timeIntervalSince(start) < 4)
    }
}
