import Foundation
import Testing
@testable import MarikaCore

private func workbenchFolder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("marika-workbench-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

struct WorkspaceFeaturesTests {
    @Test func codeScanCountsPhysicalLinesAndExcludesDependencies() async throws {
        let root = try workbenchFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        for (path, text) in [("a.swift", "// TODO FIXME\r\n\r\nlet x = 1\r\n"), ("b.ts", "const x = 1"), ("empty.ts", ""), ("node_modules/a.ts", "// FIXME"), ("notes.md", "TODO")] {
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
        }
        let scan = try await CodeScan.run(at: root)
        #expect(scan.files == 3)
        #expect(scan.linesByLanguage == ["Swift": 3, "TypeScript": 1])
        #expect(scan.markerLines == 1)
    }

    @Test func contentsSearchFindsLinesWithoutReadingDependenciesOrBinaryFiles() async throws {
        let root = try workbenchFolder(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try Data("first\nHello Marika\nlast".utf8).write(to: root.appendingPathComponent("a.swift"))
        try Data("Marika".utf8).write(to: root.appendingPathComponent("node_modules/skip.js"))
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("binary.bin"))
        let matches = try await ProjectSearch.search("marika", root: root)
        #expect(matches.count == 1)
        #expect(matches.first?.path == "a.swift" && matches.first?.line == 2 && matches.first?.column == 7)
        #expect(try await ProjectSearch.search("marika", root: root, caseSensitive: true).isEmpty)
    }

    @MainActor @Test func restorationPreservesDraftsAndFlagsDiskConflicts() async throws {
        let root = try workbenchFolder(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("disk changed".utf8).write(to: root.appendingPathComponent("file.swift"))
        var layout = ProjectLayout()
        layout.panel = .code; layout.secondary = .browser; layout.splitFraction = 0.42
        layout.files = [EditorFileState(path: "file.swift", draft: "unsaved", baseText: "old disk", line: 2)]
        layout.selectedFile = "file.swift"
        let restored = try JSONDecoder().decode(ProjectLayout.self, from: JSONEncoder().encode(layout))
        let editor = CodeWorkspace(root: root)
        await editor.restore(restored)
        #expect(editor.selectedDocument?.text == "unsaved")
        #expect(editor.selectedDocument?.changedOnDisk == true)
        #expect(editor.selectedDocument?.isModified == true)
        await editor.refresh()
        #expect(editor.selectedDocument?.changedOnDisk == true)
        #expect(await editor.save(try #require(editor.selectedDocument)) == false)
        #expect(restored.secondary == .browser && restored.splitFraction == 0.42)
        #expect(try String(contentsOf: root.appendingPathComponent("file.swift"), encoding: .utf8) == "disk changed")
    }

    @Test func previewDetectionUsesProjectScriptsAndThePackageManager() throws {
        let root = try workbenchFolder(); defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"scripts":{"dev":"vite --host 127.0.0.1"}}"#.utf8).write(to: root.appendingPathComponent("package.json"))
        try Data().write(to: root.appendingPathComponent("pnpm-lock.yaml"))
        #expect(ProjectPreview.detect(at: root)?.command == "pnpm run dev")
        #expect(ProjectPreview.detect(at: root)?.address == "http://localhost:5173")
    }

    @MainActor @Test func previewReportsItsURLAndStopsTheServer() async throws {
        let root = try workbenchFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let preview = ProjectPreview()
        try Data("Preview fixture".utf8).write(to: root.appendingPathComponent("index.html"))
        let python = "import http.server; s=http.server.ThreadingHTTPServer(('127.0.0.1',0),http.server.SimpleHTTPRequestHandler); print('(http://127.0.0.1:%s/)'%s.server_port,flush=True); s.serve_forever()"
        let command = "/usr/bin/python3 -u -c \"" + python + "\""
        preview.start(PreviewConfiguration(command: command, address: "http://localhost:1"), at: root, environment: ProcessInfo.processInfo.environment)
        defer { preview.stop() }
        for _ in 0..<100 where preview.state != .running { try await Task.sleep(for: .milliseconds(60)) }
        #expect(preview.state == .running)
        let url = try #require(preview.address)
        #expect(url.port != 1 && preview.logs.contains("http://127.0.0.1:"))
        #expect(url.path == "/")
        let (body, pageResponse) = try await URLSession.shared.data(from: url)
        #expect((pageResponse as? HTTPURLResponse)?.statusCode == 200 && String(decoding: body, as: UTF8.self) == "Preview fixture")
        preview.stop()
        try await Task.sleep(for: .milliseconds(250))
        var request = URLRequest(url: url); request.timeoutInterval = 1
        let response = try? await URLSession.shared.data(for: request)
        #expect(response == nil)
    }
}

struct AgentWorktreeTests {
    private func git(_ args: [String], root: URL) async throws -> String {
        let result = try await Command.run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", root.path] + args,
                                           environment: ProcessInfo.processInfo.environment)
        #expect(result.succeeded, Comment(rawValue: result.errorOutput))
        return result.output
    }
    private func repository(_ root: URL) async throws {
        _ = try await git(["init", "-b", "main"], root: root)
        _ = try await git(["config", "user.name", "Test"], root: root)
        _ = try await git(["config", "user.email", "test@marika.local"], root: root)
        try Data("original\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        _ = try await git(["add", "a.txt"], root: root)
        _ = try await git(["commit", "-m", "initial"], root: root)
    }

    @Test func isolatedEditsCanBeReviewedAndAppliedWithoutLosingUserChanges() async throws {
        let root = try workbenchFolder(); let managed = try workbenchFolder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: managed) }
        try await repository(root)
        try Data("user draft\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("user note".utf8).write(to: root.appendingPathComponent("notes.txt"))
        let service = AgentWorktrees(directory: managed, environment: ProcessInfo.processInfo.environment)
        var workspace = try #require(await service.create(for: root, id: UUID()))
        let isolated = URL(fileURLWithPath: workspace.workingPath)
        #expect(try String(contentsOf: isolated.appendingPathComponent("a.txt"), encoding: .utf8) == "user draft\n")
        try Data("agent change\n".utf8).write(to: isolated.appendingPathComponent("a.txt"))
        try Data("new file".utf8).write(to: isolated.appendingPathComponent("new.txt"))
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "user draft\n")
        let review = try await service.review(workspace)
        #expect(!review.isEmpty && review.files.contains { $0.path == "new.txt" })
        workspace.baseCommit = try await service.apply(review, workspace: workspace, to: root)
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "agent change\n")
        #expect(try String(contentsOf: root.appendingPathComponent("notes.txt"), encoding: .utf8) == "user note")
        #expect(try await git(["diff", "--cached", "--name-only"], root: root).isEmpty)
        try Data("follow-up change\n".utf8).write(to: isolated.appendingPathComponent("a.txt"))
        let followUp = try await service.review(workspace)
        #expect(!followUp.files.contains { $0.path == "new.txt" })
        workspace.baseCommit = try await service.apply(followUp, workspace: workspace, to: root)
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "follow-up change\n")
        try await service.discard(workspace, project: root)
        #expect(!FileManager.default.fileExists(atPath: workspace.rootPath))
    }

    @Test func conflictingReviewLeavesTheProjectUntouched() async throws {
        let root = try workbenchFolder(); let managed = try workbenchFolder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: managed) }
        try await repository(root)
        let service = AgentWorktrees(directory: managed, environment: ProcessInfo.processInfo.environment)
        let workspace = try #require(await service.create(for: root, id: UUID()))
        try Data("agent\n".utf8).write(to: URL(fileURLWithPath: workspace.workingPath).appendingPathComponent("a.txt"))
        let review = try await service.review(workspace)
        try Data("new user edit\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        await #expect(throws: AgentWorktreeError.self) { try await service.apply(review, workspace: workspace, to: root) }
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "new user edit\n")
        try await service.discard(workspace, project: root)
    }
}
