import Foundation
import Testing

@testable import MarikaCore

private func makeEditorProject() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("marika-editor-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

struct ProjectFilesTests {
    @Test func openingRoutesMediaAndLargeFilesToPreviewsWhileKeepingCodeEditable() async throws {
        let root = try makeEditorProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ProjectFiles(root: root)
        try Data("let answer = 42".utf8).write(to: root.appendingPathComponent("code.swift"))
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8).write(to: root.appendingPathComponent("image.svg"))
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("asset.bin"))
        try Data(repeating: 65, count: ProjectFiles.maxFileBytes + 1).write(to: root.appendingPathComponent("large.txt"))
        guard case .text(let code) = try await files.open("code.swift") else { Issue.record("Code should remain editable"); return }
        #expect(code.text == "let answer = 42")
        for path in ["image.svg", "asset.bin", "large.txt"] {
            guard case .preview(let preview) = try await files.open(path) else { Issue.record("Expected preview for \(path)"); continue }
            #expect(preview.url.lastPathComponent == path)
            #expect(preview.byteCount > 0)
        }
    }

    @Test func previewCannotEscapeProjectOrOpenDirectories() async throws {
        let root = try makeEditorProject()
        let outside = try makeEditorProject()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let image = outside.appendingPathComponent("image.png")
        try Data([0, 1, 2, 3]).write(to: image)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside.png"), withDestinationURL: image)
        let files = ProjectFiles(root: root)
        await #expect(throws: ProjectFileError.outsideProject) { try await files.open("outside.png") }
        await #expect(throws: ProjectFileError.notRegularFile) { try await files.preview("") }
    }

    @Test func fileIndexSkipsDependenciesAndDoesNotTraverseSymlinkDirectories() async throws {
        let root = try makeEditorProject()
        let outside = try makeEditorProject()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        for directory in ["Sources/Nested", "node_modules/pkg", ".build/debug", ".git/objects"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
            try Data().write(to: root.appendingPathComponent(directory + "/file.txt"))
        }
        try Data().write(to: root.appendingPathComponent(".gitignore"))
        try Data().write(to: outside.appendingPathComponent("outside.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked-folder"), withDestinationURL: outside)
        let paths = try await ProjectFiles(root: root).filePaths()
        #expect(paths.contains("Sources/Nested/file.txt"))
        #expect(paths.contains(".gitignore"))
        #expect(!paths.contains { $0.hasPrefix("node_modules/") || $0.hasPrefix(".build/") || $0.hasPrefix(".git/") })
        #expect(!paths.contains { $0.contains("outside.txt") })
    }

    @Test func directoriesAreLazySortedAndKeepConfigFiles() async throws {
        let root = try makeEditorProject()
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["Sources", "node_modules", ".git"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for name in ["README.md", ".gitignore", "Sources/Main.swift"] {
            try "text".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let files = ProjectFiles(root: root)
        let entries = try await files.entries()
        #expect(entries.map(\.name) == ["Sources", ".gitignore", "README.md"])
        #expect(try await files.entries(in: "Sources").map(\.path) == ["Sources/Main.swift"])
    }

    @Test func savesPreserveCRLFBOMAndExecutablePermissions() async throws {
        let root = try makeEditorProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("script.sh")
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("#!/bin/sh\r\necho hello\r\n".utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let files = ProjectFiles(root: root)
        let snapshot = try await files.read("script.sh")
        #expect(snapshot.text == "#!/bin/sh\r\necho hello\r\n")
        let updated = try await files.write(snapshot.text.replacingOccurrences(of: "hello", with: "goodbye"), replacing: snapshot)
        #expect(updated.data.starts(with: [0xEF, 0xBB, 0xBF]))
        #expect(String(decoding: updated.data.dropFirst(3), as: UTF8.self) == "#!/bin/sh\r\necho goodbye\r\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o755)
    }

    @Test func agentChangesAreNeverSilentlyOverwritten() async throws {
        let root = try makeEditorProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("file.txt")
        try Data("original".utf8).write(to: url)
        let files = ProjectFiles(root: root)
        let snapshot = try await files.read("file.txt")
        try Data("agent's edit".utf8).write(to: url)
        await #expect(throws: ProjectFileError.changedOnDisk) { try await files.write("my edit", replacing: snapshot) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "agent's edit")
        let updated = try await files.write("my edit", replacing: snapshot, overwrite: true)
        #expect(updated.text == "my edit")
        #expect(try String(contentsOf: url, encoding: .utf8) == "my edit")
    }

    @Test func deletedFilesRequireAnExplicitOverwrite() async throws {
        let root = try makeEditorProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("file.txt")
        try Data("original".utf8).write(to: url)
        let files = ProjectFiles(root: root)
        let snapshot = try await files.read("file.txt")
        try FileManager.default.removeItem(at: url)
        await #expect(throws: ProjectFileError.changedOnDisk) { try await files.write("my edit", replacing: snapshot) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func traversalAndOutsideSymlinksCannotBeReadOrWritten() async throws {
        let root = try makeEditorProject()
        let outside = try makeEditorProject()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("outside".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.txt"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
        let files = ProjectFiles(root: root)
        await #expect(throws: ProjectFileError.outsideProject) { try await files.read("linked.txt") }
        await #expect(throws: ProjectFileError.outsideProject) { try await files.entries(in: "../") }
        await #expect(throws: ProjectFileError.outsideProject) { try await files.read(outside.path + "/secret.txt") }
        try Data("inside".utf8).write(to: root.appendingPathComponent("valid.txt"))
        var snapshot = try await files.read("valid.txt")
        snapshot.path = "linked.txt"
        await #expect(throws: ProjectFileError.outsideProject) { try await files.write("bad", replacing: snapshot, overwrite: true) }
        #expect(try String(contentsOf: outside.appendingPathComponent("secret.txt"), encoding: .utf8) == "outside")
    }

    @Test func binaryAndOversizedFilesAreRejectedAndUTF16IsSupported() async throws {
        let root = try makeEditorProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("binary"))
        try Data(repeating: 65, count: ProjectFiles.maxFileBytes + 1).write(to: root.appendingPathComponent("large"))
        try "Hello κόσμε\r\n".data(using: .utf16)!.write(to: root.appendingPathComponent("utf16.txt"))
        let files = ProjectFiles(root: root)
        await #expect(throws: ProjectFileError.notText) { try await files.read("binary") }
        await #expect(throws: ProjectFileError.tooLarge) { try await files.read("large") }
        let snapshot = try await files.read("utf16.txt")
        let updated = try await files.write(snapshot.text + "Again\r\n", replacing: snapshot)
        #expect(try await files.read("utf16.txt").text == updated.text)
    }
}

@MainActor
struct CodeWorkspaceTests {
    @Test func fileHistoryPreservesBuffersAndBranchesFromTheCurrentVisit() async throws {
        let root = try makeEditorProject()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.swift", "b.swift", "c.swift", "d.swift"] {
            try Data(name.utf8).write(to: root.appendingPathComponent(name))
        }
        let editor = CodeWorkspace(root: root)
        await editor.open("a.swift")
        let first = try #require(editor.selectedDocument)
        first.text = "unsaved A"
        #expect(!editor.canGoBack && !editor.canGoForward)
        await editor.open("b.swift", focus: false)
        await editor.open("a.swift")
        await editor.open("c.swift")
        editor.goBack()
        #expect(editor.selectedDocument === first)
        #expect(editor.focusEditorOnSelection)
        editor.goBack()
        #expect(editor.selectedDocument?.path == "b.swift")
        editor.goForward()
        #expect(editor.selectedDocument === first)
        // Refocusing the same file must not erase Forward or add another visit.
        await editor.open("a.swift")
        #expect(editor.canGoForward)
        await editor.open("d.swift")
        #expect(!editor.canGoForward)
        editor.goBack()
        #expect(editor.selectedDocument === first)
        #expect(first.text == "unsaved A")
        #expect(editor.recentFilePaths.prefix(2) == ["a.swift", "d.swift"])
        #expect(try String(contentsOf: root.appendingPathComponent("a.swift"), encoding: .utf8) == "a.swift")
    }

    @Test func closingFilesRemovesTheirHistoryWithoutReopeningThem() async throws {
        let root = try makeEditorProject()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.txt", "b.txt", "c.txt"] {
            try Data(name.utf8).write(to: root.appendingPathComponent(name))
        }
        let editor = CodeWorkspace(root: root)
        await editor.open("a.txt")
        let first = try #require(editor.selectedDocument)
        await editor.open("b.txt")
        let second = try #require(editor.selectedDocument)
        await editor.open("c.txt")
        let third = try #require(editor.selectedDocument)
        editor.goBack()
        editor.close(first)
        #expect(editor.selectedDocument === second)
        #expect(!editor.canGoBack && editor.canGoForward)
        editor.goForward()
        #expect(editor.selectedDocument === third)
        editor.close(third)
        #expect(editor.selectedDocument === second)
        #expect(!editor.canGoBack && !editor.canGoForward)
        editor.close(second)
        #expect(editor.selectedDocument == nil && editor.navigatorSelection == nil)
        #expect(!editor.canGoBack && !editor.canGoForward)
        editor.goBack()
        editor.goForward()
        #expect(editor.documents.isEmpty)
    }

    @Test func previewTabsPreserveCodeEditsAndNeverWriteBinaryFiles() async throws {
        let root = try makeEditorProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("image.png")
        let original = Data([0, 1, 2, 3])
        try original.write(to: image)
        try Data("let answer = 42".utf8).write(to: root.appendingPathComponent("code.swift"))
        let editor = CodeWorkspace(root: root)
        await editor.open("code.swift")
        let code = try #require(editor.selectedDocument)
        code.text = "my unsaved code"
        await editor.open("image.png")
        let preview = try #require(editor.selectedDocument)
        #expect(!preview.isEditable)
        #expect(!preview.isModified)
        #expect(preview.preview?.byteCount == 4)
        #expect(await editor.save(preview, overwrite: true) == false)
        #expect(try Data(contentsOf: image) == original)
        try Data([0, 1, 2, 3, 4]).write(to: image)
        await editor.refresh()
        #expect(preview.preview?.byteCount == 5)
        await editor.open("code.swift")
        #expect(editor.selectedDocument === code)
        #expect(code.text == "my unsaved code")
        #expect(editor.modifiedDocuments.count == 1)
    }

    @Test func navigationPreservesEditsAndDistinguishesListFocusFromEditorFocus() async throws {
        let root = try makeEditorProject()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.swift", "b.swift"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        let editor = CodeWorkspace(root: root)
        await editor.open("a.swift")
        let first = try #require(editor.selectedDocument)
        first.text = "my unsaved change"
        let focus = editor.editorFocusRequest
        await editor.open("b.swift", focus: false)
        #expect(!editor.focusEditorOnSelection)
        #expect(editor.editorFocusRequest == focus)
        #expect(editor.navigatorSelection == "b.swift")
        editor.selectAdjacentDocument(1)
        #expect(editor.selectedDocument === first)
        #expect(editor.focusEditorOnSelection)
        #expect(editor.editorFocusRequest > focus)
        #expect(first.text == "my unsaved change")
        editor.selectAdjacentDocument(-1)
        #expect(editor.selectedDocument?.path == "b.swift")
    }

    @Test func openingNestedFileRevealsItsParentsAndSearchFindsItWithoutExpansion() async throws {
        let root = try makeEditorProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/Views"), withIntermediateDirectories: true)
        try Data("struct MainView {}".utf8).write(to: root.appendingPathComponent("Sources/Views/MainView.swift"))
        let editor = CodeWorkspace(root: root)
        await editor.loadDirectory()
        #expect(await editor.searchFiles("mv") == ["Sources/Views/MainView.swift"])
        #expect(editor.expandedDirectories.isEmpty)
        await editor.open("Sources/Views/MainView.swift")
        #expect(editor.expandedDirectories == ["Sources", "Sources/Views"])
        #expect(editor.visibleEntries.map(\.id) == ["Sources", "Sources/Views", "Sources/Views/MainView.swift"])
        #expect(editor.navigatorSelection == "Sources/Views/MainView.swift")
    }

    @Test func revealingDirectoryClearsSearchAndShowsItsParentsWithoutChangingTheOpenFile() async throws {
        let root = try makeEditorProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/Views"), withIntermediateDirectories: true)
        try Data("struct MainView {}".utf8).write(to: root.appendingPathComponent("Sources/Views/MainView.swift"))
        let editor = CodeWorkspace(root: root)
        await editor.open("Sources/Views/MainView.swift")
        let document = try #require(editor.selectedDocument)
        document.text = "unsaved changes"
        editor.expandedDirectories = []
        editor.showsNavigator = false
        editor.navigatorQuery = "missing"
        await editor.revealDirectory("Sources/Views")
        #expect(editor.showsNavigator)
        #expect(editor.navigatorQuery.isEmpty)
        #expect(editor.expandedDirectories == ["Sources", "Sources/Views"])
        #expect(editor.navigatorSelection == "Sources/Views")
        #expect(editor.selectedDocument === document)
        #expect(document.text == "unsaved changes")
        #expect(editor.visibleEntries.contains { $0.id == "Sources/Views/MainView.swift" })
    }

    @Test func switchingFilesPreservesBothUnsavedBuffers() async throws {
        let root = try makeEditorProject()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.swift", "b.swift"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        let editor = CodeWorkspace(root: root)
        await editor.open("a.swift")
        let first = try #require(editor.selectedDocument)
        first.text = "unsaved A"
        await editor.open("b.swift")
        let second = try #require(editor.selectedDocument)
        second.text = "unsaved B"
        await editor.open("a.swift")
        #expect(editor.documents.count == 2)
        #expect(editor.selectedDocument === first)
        #expect(editor.modifiedDocuments.count == 2)
        #expect(first.text == "unsaved A")
        #expect(second.text == "unsaved B")
        #expect(try String(contentsOf: root.appendingPathComponent("a.swift"), encoding: .utf8) == "a.swift")
    }

    @Test func refreshReloadsCleanFilesButPreservesConflictingEdits() async throws {
        let root = try makeEditorProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("file.txt")
        try Data("original".utf8).write(to: url)
        let editor = CodeWorkspace(root: root)
        await editor.open("file.txt")
        let document = try #require(editor.selectedDocument)
        try Data("first agent edit".utf8).write(to: url)
        await editor.refresh()
        #expect(document.text == "first agent edit")
        #expect(!document.isModified)
        document.text = "my pending edit"
        try Data("second agent edit".utf8).write(to: url)
        await editor.refresh()
        #expect(document.text == "my pending edit")
        #expect(document.changedOnDisk)
        #expect(await editor.save(document) == false)
        #expect(try String(contentsOf: url, encoding: .utf8) == "second agent edit")
        await editor.reload(document)
        #expect(document.text == "second agent edit")
        #expect(!document.isModified)
        #expect(!document.changedOnDisk)
    }

    @Test func savingNotifiesTheChangesPanelAndClosingSelectsANeighbor() async throws {
        let root = try makeEditorProject()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.txt", "b.txt"] { try Data("original".utf8).write(to: root.appendingPathComponent(name)) }
        let editor = CodeWorkspace(root: root)
        var saves = 0
        editor.onSave = { saves += 1 }
        await editor.open("a.txt")
        let first = try #require(editor.selectedDocument)
        first.text = "saved change"
        #expect(await editor.save(first))
        #expect(saves == 1)
        #expect(!first.isModified)
        await editor.open("b.txt")
        let second = try #require(editor.selectedDocument)
        editor.close(second)
        #expect(editor.selectedDocument === first)
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "saved change")
    }
}

struct FileSearchTests {
    @Test func emptyQueriesPreferMaintainedFilesWithoutHidingBuildOutput() {
        let paths = ["build/readme-capture.log", "dist/app.js", "docs/README.md", "README.md", "Sources/Main.swift"]
        let matches = FileSearch.matches(paths, query: "")
        #expect(Array(matches.prefix(3)) == ["README.md", "docs/README.md", "Sources/Main.swift"])
        #expect(Set(matches) == Set(paths))
        #expect(FileSearch.matches(paths, query: "  ", limit: 1) == ["README.md"])
        #expect(FileSearch.matches(paths, query: "", limit: 0).isEmpty)
    }

    @Test func readmeSearchPrefersExactStemsAndProjectSourcesOverBuildArtifacts() {
        let paths = ["build/readme-capture.log", "build/readme-preview.html", "build/readme-render.html",
                     "build/README.md", "docs/README.md", "README.md", "scripts/capture-readme.py"]
        let matches = FileSearch.matches(paths, query: "README")
        #expect(Array(matches.prefix(3)) == ["README.md", "docs/README.md", "build/README.md"])
        #expect(matches.contains("build/readme-preview.html"))
        #expect(FileSearch.matches(paths, query: "readme.md").first == "README.md")
    }

    @Test func equallyRelevantOutputFilesRankBelowSourceButExplicitPathsStillWork() {
        let paths = ["build/Views/Main.swift", "Sources/Views/Main.swift", "dist/Main.swift", "Sources/Main.swift"]
        #expect(FileSearch.matches(paths, query: "Main").prefix(2) == ["Sources/Main.swift", "Sources/Views/Main.swift"])
        #expect(FileSearch.matches(paths, query: "build/Views/Main.swift").first == "build/Views/Main.swift")
        #expect(FileSearch.matches(paths, query: "dist main").first == "dist/Main.swift")
        #expect(FileSearch.matches(paths, query: "Main", limit: 1) == ["Sources/Main.swift"])
    }

    @Test func filenamesRankBeforePathMatchesAndAbbreviationsWork() {
        let paths = ["CodeWorkspace/Other.swift", "Sources/CodeWorkspaceTests.swift", "Sources/CodeWorkspace.swift", "Notes/Workspace.md"]
        #expect(FileSearch.matches(paths, query: "CodeWorkspace.swift").first == "Sources/CodeWorkspace.swift")
        #expect(FileSearch.matches(paths, query: "codeworkspace").first == "Sources/CodeWorkspace.swift")
        #expect(FileSearch.matches(paths, query: "cws").contains("Sources/CodeWorkspace.swift"))
        #expect(FileSearch.matches(paths, query: "sources workspace tests") == ["Sources/CodeWorkspaceTests.swift"])
        #expect(FileSearch.matches(paths, query: "not-a-file").isEmpty)
        #expect(FileSearch.matches(paths, query: "", limit: 2) == ["CodeWorkspace/Other.swift", "Notes/Workspace.md"])
    }
}
