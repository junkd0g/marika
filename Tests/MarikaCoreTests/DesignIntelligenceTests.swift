import Foundation
import Testing
@testable import MarikaCore

struct DesignIntelligenceTests {
    private let uri = "file:///project/Service.swift"
    private func symbols(line: Int = 2, second: Bool = false) -> [SourceSymbol] {
        func method(_ detail: String, _ row: Int) -> JSONValue {
            ["name": "run", "kind": 6, "detail": .string(detail),
             "range": ["start": ["line": .int(Int64(row)), "character": 0], "end": ["line": .int(Int64(row + 3)), "character": 1]],
             "selectionRange": ["start": ["line": .int(Int64(row)), "character": 5], "end": ["line": .int(Int64(row)), "character": 8]]]
        }
        let children = second ? [method("(Int) -> Void", line), method("(String) -> Void", line + 5)] : [method("(Int) -> Void", line)]
        return SourceSymbols.parse([["name": "Service", "kind": 5,
            "range": ["start": ["line": 0, "character": 0], "end": ["line": 20, "character": 1]],
            "children": .array(children)]], documentURI: uri)
    }
    @Test func symbolIdentitySurvivesMovementAndDisambiguatesOverloads() throws {
        let original = try #require(symbols().first { $0.name == "run" })
        let link = DesignSourceLink(kind: .symbol, target: "Service.swift", line: 3, symbol: "run", symbolIdentity: original.identity)
        let result = try SourceSymbols.resolve(link, in: symbols(line: 8, second: true))
        #expect(result.position == SourcePosition(line: 8, character: 5))
        #expect(result.identity.path == ["Service", "run"] && result.length == 3)
        let legacy = DesignSourceLink(kind: .symbol, target: "Service.swift", line: 3, symbol: "run")
        #expect(throws: SymbolLookupError.ambiguous("run")) { try SourceSymbols.resolve(legacy, in: symbols(second: true)) }
        #expect(throws: SymbolLookupError.missing("run")) { try SourceSymbols.resolve(legacy, in: []) }
        #expect(try JSONDecoder().decode(DesignSourceLink.self, from: JSONEncoder().encode(link)) == link)
    }
    @Test func flatSymbolsExcludeOtherFilesAndMalformedLocations() {
        let range: JSONValue = ["start": ["line": 3, "character": 2], "end": ["line": 3, "character": 6]]
        let response: JSONValue = [
            ["name": "run", "containerName": "Service", "kind": 6, "location": ["uri": .string(uri), "range": range]],
            ["name": "foreign", "kind": 6, "location": ["uri": "file:///other.swift", "range": range]],
            ["name": "invalid", "kind": 6, "range": ["start": ["line": -1, "character": 0]]]
        ]
        let result = SourceSymbols.parse(response, documentURI: uri)
        #expect(result.count == 1 && result[0].identity.name == "Service.run")
    }
    @Test func auditFindsBrokenLinksAndDisconnectedComponentsWithoutChangingDocument() async throws {
        var doc = DesignDocument()
        let a = doc.addComponent(.api, centeredAt: .zero), b = doc.addComponent(.database, centeredAt: CGPoint(x: 400, y: 0))
        doc.update([a]) { $0.links = [DesignSourceLink(kind: .file, target: "missing.swift"), DesignSourceLink(kind: .endpoint, target: "GET /removed")] }
        doc.update([b]) { $0.links = [DesignSourceLink(kind: .symbol, target: "Service.swift", symbol: "removed"), DesignSourceLink(kind: .documentation, target: "https://example.invalid/docs")] }
        let original = doc
        let report = try await DesignHealth.scan(doc, endpointIDs: [], file: { $0 == "missing.swift" ? .missing : .present }, symbols: { _ in .success([]) })
        #expect(report.filter { $0.kind == .disconnected }.count == 2)
        #expect(Set(report.filter(\.needsRepair).map(\.kind)) == [.missingFile, .missingEndpoint, .missingSymbol])
        #expect(doc == original)
        doc.connect(a, b)
        let connected = try await DesignHealth.scan(doc, endpointIDs: ["GET /removed"], file: { _ in .present }, symbols: { _ in .failure(.unsupported) })
        #expect(!connected.contains { $0.kind == .disconnected || $0.kind == .missingSymbol })
        #expect(connected.count == 1 && connected[0].kind == .unverified)
    }
    @Test func auditCachesSymbolRequestsAndDoesNotCheckDocumentationOverNetwork() async throws {
        actor Counter { var value = 0; func increment() { value += 1 } }
        let counter = Counter(), declarations = symbols()
        var doc = DesignDocument()
        let id = doc.add(.rectangle, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        doc.update([id]) { $0.links = [DesignSourceLink(kind: .symbol, target: "Service.swift", symbol: "run"), DesignSourceLink(kind: .symbol, target: "Service.swift", symbol: "Service"), DesignSourceLink(kind: .documentation, target: "https://example.invalid")] }
        let report = try await DesignHealth.scan(doc, endpointIDs: [], file: { _ in .present }, symbols: { _ in
            await counter.increment(); return .success(declarations)
        })
        let count = await counter.value
        #expect(report.isEmpty && count == 1)
    }
    @Test func fileAuditRejectsEscapingSymlinksAndDistinguishesMissingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "hello".write(to: root.appendingPathComponent("source.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("outside").path, withDestinationPath: "/etc/hosts")
        #expect(await DesignHealth.file("source.swift", root: root) == .present)
        #expect(await DesignHealth.file("removed.swift", root: root) == .missing)
        #expect(await DesignHealth.file("outside", root: root) == .outsideProject)
        #expect(await DesignHealth.file("../outside", root: root) == .outsideProject)
    }
    @Test @MainActor func sourceChecksPreferUnsavedEditsAndOtherwiseReadFreshDiskWithoutChangingTheEditor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.swift")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let editor = CodeWorkspace(root: root)
        await editor.open("source.swift")
        let document = try #require(editor.selectedDocument)
        try "changed on disk".write(to: file, atomically: true, encoding: .utf8)
        #expect(try await editor.currentSourceText("source.swift") == "changed on disk")
        #expect(document.text == "old" && !document.isModified)
        document.text = "unsaved change"
        #expect(try await editor.currentSourceText("source.swift") == "unsaved change")
        #expect(try String(contentsOf: file, encoding: .utf8) == "changed on disk")
    }
}
