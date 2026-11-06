import Foundation
import Testing
@testable import MarikaCore

private let ideTools = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".tools/bin")
private actor IDEEvents {
    var diagnostics: [JSONValue] = []
    func append(_ value: JSONValue) { diagnostics += value["params"]?["diagnostics"]?.array ?? [] }
}
@Suite(.serialized) struct IDETests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "module example.test/demo\n\ngo 1.24\n".write(to: root.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        return root
    }
    private var env: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ideTools.path + ":/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        return environment
    }
    @Test func framedMessagesHandleUnicodeAndArbitraryChunks() throws {
        let values: [JSONValue] = [["id": 1, "result": "hello 🦊"], ["id": 2, "result": ["value": 42]]]
        let data = try values.reduce(Data()) { $0 + (try RPCFrames.encode($1)) }
        var parser = RPCFrames(), result: [JSONValue] = []
        for byte in data { result += try parser.append(Data([byte])) }
        #expect(result == values)
        #expect(throws: AgentError.self) { var invalid = RPCFrames(); _ = try invalid.append(Data("Content-Length: -2\r\n\r\n{}".utf8)) }
    }
    @Test func editsRespectUTF16AndRejectOverlap() throws {
        let source = "🦊 value\n"
        let range: JSONValue = ["start": ["line": 0, "character": 3], "end": ["line": 0, "character": 8]]
        #expect(try SourcePosition.applying([["range": range, "newText": "result"]], to: source) == "🦊 result\n")
        #expect(throws: AgentError.self) { try SourcePosition.applying([["range": range, "newText": "a"], ["range": range, "newText": "b"]], to: source) }
        let (text, carets) = try EditorOperations.replace("a a", ranges: [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)], with: "bb")
        #expect(text == "bb bb"); #expect(carets == [NSRange(location: 2, length: 0), NSRange(location: 5, length: 0)])
    }
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: ideTools.appendingPathComponent("gopls").path)))
    func realGoLanguageServerProvidesNavigationRenameAndDiagnostics() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "package main\nfunc add(a,b int) int {return a+b}\nfunc main(){ _ = add(1,2) }\n"
        try text.write(to: root.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
        let server = LanguageService(executable: ideTools.appendingPathComponent("gopls"), arguments: [], root: root, environment: env)
        let collector = IDEEvents()
        let listener = Task { for await event in server.events { await collector.append(event); if event["id"] != nil { await server.respond(event) } } }
        try await server.start()
        try await server.synchronize(path: "main.go", text: text)
        let definition = try await server.request("textDocument/definition", path: "main.go", position: SourcePosition(line: 2, character: 18))
        #expect(!(definition.array ?? []).isEmpty)
        let renamed = try await server.request("textDocument/rename", path: "main.go", position: SourcePosition(line: 1, character: 6), extra: ["newName": "sum"])
        #expect(renamed["documentChanges"]?.array?.isEmpty == false || renamed["changes"]?.object?.isEmpty == false)
        try await server.synchronize(path: "main.go", text: "package main\nfunc main(){ missing() }\n")
        for _ in 0..<100 { if await !collector.diagnostics.isEmpty { break }; try await Task.sleep(for: .milliseconds(100)) }
        #expect(await collector.diagnostics.contains { $0["message"]?.string?.contains("missing") == true })
        await server.close(); listener.cancel()
    }
    @Test func goTestsProduceIndividualResultsAndCoverage() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "package demo\nfunc Add(a,b int) int { return a+b }\n".write(to: root.appendingPathComponent("add.go"), atomically: true, encoding: .utf8)
        try "package demo\nimport \"testing\"\nfunc TestAdd(t *testing.T){if Add(2,3)!=5 {t.Fatal(\"bad\")}}\n".write(to: root.appendingPathComponent("add_test.go"), atomically: true, encoding: .utf8)
        let context = ToolContext(root: root, environment: env)
        let tests = try await ProjectTests.discover(context: context, framework: "Go")
        #expect(tests.count == 1)
        let result = try await ProjectTests.run(context: context, framework: "Go", test: tests.first)
        #expect(result.succeeded); #expect(result.statuses.values.contains("pass")); #expect(!result.coverage.isEmpty)
        #expect(!result.output.hasPrefix("{"))
    }
    @MainActor @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: ideTools.appendingPathComponent("dlv").path)))
    func realGoDebuggerStopsAtBreakpointAndInspectsValue() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "package main\nfunc main(){\n value := 41\n println(value + 1)\n}\n".write(to: root.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
        let debugger = DebuggerSession()
        await debugger.start(executable: ideTools.appendingPathComponent("dlv"), arguments: [], root: root, environment: env,
            configuration: ["request": "launch", "mode": "debug", "program": .string(root.path), "stopOnEntry": false], breakpoints: ["main.go": [4]], go: true)
        for _ in 0..<100 { if debugger.isPaused || debugger.error != nil { break }; try await Task.sleep(for: .milliseconds(100)) }
        #expect(debugger.error == nil, Comment(rawValue: debugger.error ?? ""))
        #expect(debugger.isPaused)
        await debugger.evaluate("value")
        #expect(debugger.watches["value"] == "41")
        await debugger.stop()
    }
}
