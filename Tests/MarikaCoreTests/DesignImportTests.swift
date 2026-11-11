import Foundation
import Testing
@testable import MarikaCore

struct DesignImportTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("design-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func write(_ text: String, _ path: String, at root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private var files: [DesignImportFile] { [DesignImportFile(path: "Screen.swift", framework: "SwiftUI", bytes: 100, digest: "fixture", lines: 10)] }
    private func response(target: String = "Screen.swift", line: Int = 2) -> String {
        ##"{"summary":"Imported checkout and its visual language","notes":["Runtime data uses placeholders"],"design":{"title":"Checkout","nodes":[{"id":"screen","kind":"frame","name":"Checkout","width":500,"height":400,"text":"","links":[{"kind":"file","target":"TARGET","line":LINE}]},{"id":"button","name":"Pay","text":"Pay now","description":"Submits the checkout form.","x":40,"y":80,"width":200,"height":44,"fill":"#6254D9"}],"connections":[{"from":"button","to":"screen","label":"Submit","fromPort":"bottom","style":"event"}]}}"##
            .replacingOccurrences(of: "TARGET", with: target).replacingOccurrences(of: "LINE", with: String(line))
    }

    @Test func discoversSupportedUIStacksAndSkipsDependenciesAndSymlinks() async throws {
        let root = try directory(), outside = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        for (path, text) in [("Screen.swift", "import SwiftUI\nstruct Screen: View {}"), ("Screen.kt", "@Composable fun Screen() {}"),
                             ("index.html", "<button>Pay</button>"), ("App.tsx", "export const App = () => <button>Pay</button>"),
                             ("Screen.vue", "<template><button>Pay</button></template>"), ("theme.css", ":root { --accent: #6254D9; }"),
                             ("node_modules/lib/Hidden.tsx", "ignored"), ("build/Generated.swift", "ignored"), (".env", "private"), ("types.d.ts", "ignored")] {
            try write(text, path, at: root)
        }
        try write("private", "Outside.swift", at: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Linked.swift"), withDestinationURL: outside.appendingPathComponent("Outside.swift"))
        let found = try await DesignImportSources.discover(at: root)
        #expect(Set(found.map(\.path)) == ["Screen.swift", "Screen.kt", "index.html", "App.tsx", "Screen.vue", "theme.css"])
        #expect(Set(found.map(\.framework)) == ["SwiftUI", "Kotlin / Compose", "HTML", "React", "Vue", "Styles"])
    }

    @Test func sourceSnapshotsDetectChangesAndKeepThePromptBounded() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("import SwiftUI\nText(\"Hello 🌍\")\n", "Screen.swift", at: root)
        let snapshot = try await DesignImportSources.capture(["Screen.swift"], at: root)
        #expect(snapshot.files[0].lines == 3 && snapshot.files[0].digest?.count == 64)
        let prompt = try DesignImportPrompt.make(snapshot: snapshot, focus: "Main screen")
        #expect(prompt.contains("Screen.swift") && prompt.contains("Hello 🌍") && prompt.contains("read-only"))
        #expect(prompt.count <= 32_000)
        try await DesignImportSources.verify(snapshot.files, at: root)
        try write("changed", "Screen.swift", at: root)
        await #expect(throws: DesignToolError.self) { try await DesignImportSources.verify(snapshot.files, at: root) }
        #expect(throws: DesignToolError.self) { try DesignImportPrompt.make(snapshot: snapshot, focus: String(repeating: "x", count: 1001)) }
    }

    @Test func sourceCaptureRejectsEscapesDependenciesAndOversizedFiles() async throws {
        let root = try directory(), outside = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try write("private", "Hidden.swift", at: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Escape.swift"), withDestinationURL: outside.appendingPathComponent("Hidden.swift"))
        try write(String(repeating: "x", count: 200_001), "Large.swift", at: root)
        for path in ["../Hidden.swift", ".env", "node_modules/Screen.tsx", "Large.swift", "Escape.swift"] {
            await #expect(throws: (any Error).self) { try await DesignImportSources.capture([path], at: root) }
        }
        await #expect(throws: DesignToolError.self) { try await DesignImportSources.capture([], at: root) }
    }

    @Test func analysisUsesOnlyCapturedSourceCopiesWithoutProjectConfiguration() async throws {
        let root = try directory(), id = UUID()
        let staged = DesignImportSources.workingDirectory(for: id)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: staged) }
        try write("import SwiftUI\nText(\"Original\")", "UI/Screen.swift", at: root)
        try write("must not be loaded", ".claude/settings.json", at: root)
        let snapshot = try await DesignImportSources.capture(["UI/Screen.swift"], at: root)
        try await DesignImportSources.stage(snapshot, id: id)
        try write("Changed after capture", "UI/Screen.swift", at: root)
        #expect(try String(contentsOf: staged.appendingPathComponent("UI/Screen.swift"), encoding: .utf8).contains("Original"))
        #expect(!FileManager.default.fileExists(atPath: staged.appendingPathComponent(".claude/settings.json").path))
        let permissions = try FileManager.default.attributesOfItem(atPath: staged.appendingPathComponent("UI/Screen.swift").path)[.posixPermissions] as? Int
        #expect(permissions == 0o400)
        await DesignImportSources.discardStage(id: id)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func parsesEditableSourceLinkedDraftWithoutPublishingIt() throws {
        let draft = try DesignImportProposal.parse("```json\n" + response() + "\n```", files: files)
        #expect(draft.document.nodes.count == 2 && draft.document.title == "Checkout")
        #expect(draft.document.nodes[1].description == "Submits the checkout form.")
        #expect(draft.document.nodes[0].links?.first?.line == 2)
        #expect(draft.notes == ["Runtime data uses placeholders"])
        #expect(draft.document.connections?.first?.style == .event)
    }

    @Test func draftRejectsInventedSourceLinksAndInvalidOutput() throws {
        for invalid in [response(target: "Other.swift"), response(line: 11), response(line: 0), "A design will be generated later.",
                        response().replacingOccurrences(of: "\"width\":500", with: "\"width\":0")] {
            #expect(throws: (any Error).self) { try DesignImportProposal.parse(invalid, files: files) }
        }
    }

    @Test @MainActor func acceptingAProposalPreservesExistingLayersStylesAndUndo() throws {
        let proposal = try DesignImportProposal.parse(response(), files: files)
        var original = DesignDocument()
        let old = original.add(.rectangle, in: CGRect(x: 0, y: 0, width: 100, height: 50))
        original.update([old]) { $0.isLocked = true; $0.description = "Keep this" }
        let editor = DesignWorkspace(document: original)
        let merged = try proposal.appending(to: editor.document)
        #expect(merged.document.node(old) == original.node(old))
        #expect(merged.document.nodes.count == 4 && merged.document.nodes[1].kind == .frame)
        #expect(merged.document.node(merged.selection)?.name == "Checkout")
        #expect(merged.document.connections?.first?.style == .event && merged.document.connections?.first?.fromPort == .bottom)
        #expect(Set(merged.document.nodes.map(\.id)).count == merged.document.nodes.count)
        #expect(merged.document.nodes.dropFirst().allSatisfy { $0.x > original.node(old)!.frame.maxX })
        editor.edit { $0 = merged.document }
        editor.undo(); #expect(editor.document == original)
        editor.redo(); #expect(editor.document == merged.document)
    }

    @Test func pendingImportsSurviveWorkspacePersistenceAndOldProjectsStillDecode() throws {
        var project = Project(path: "/tmp/fixture")
        var run = DesignImportRun(projectPath: project.path, agent: .codex)
        run.status = .ready; run.files = files; run.proposal = try DesignImportProposal.parse(response(), files: files)
        project.designImport = run
        let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(restored.designImport == run)
        let legacy = try JSONDecoder().decode(Project.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","path":"/tmp/old","name":"Old"}"#.utf8))
        #expect(legacy.designImport == nil)
    }
}
