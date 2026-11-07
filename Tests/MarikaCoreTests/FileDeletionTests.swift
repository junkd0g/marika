import Foundation
import Testing
@testable import MarikaCore

private func deletionFolder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("marika-delete-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.resolvingSymlinksInPath()
}

private func deletionFiles(root: URL, trash: URL) -> ProjectFiles {
    ProjectFiles(root: root) { source in
        let target = trash.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.moveItem(at: source, to: target)
        return target
    }
}

struct FileTrashTests {
    @Test func filesAndFoldersMoveWithoutPermanentDeletion() async throws {
        let root = try deletionFolder(), trash = try deletionFolder()
        defer { for url in [root, trash] { try? FileManager.default.removeItem(at: url) } }
        try Data("saved contents".utf8).write(to: root.appendingPathComponent("file.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder/deep"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("folder/deep/asset.bin"))
        let files = deletionFiles(root: root, trash: trash)
        let file = try #require(try await files.trash("file.txt"))
        let folder = try #require(try await files.trash("folder"))
        #expect(try await files.entries().isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "saved contents")
        #expect(try Data(contentsOf: folder.appendingPathComponent("deep/asset.bin")) == Data([1, 2, 3]))
        // A moved item can be restored using normal filesystem operations.
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("file.txt"))
        #expect(try await files.read("file.txt").text == "saved contents")
    }

    @Test func rootTraversalGitMetadataAndOutsideParentsCannotBeTrashed() async throws {
        let root = try deletionFolder(), trash = try deletionFolder(), outside = try deletionFolder()
        defer { for url in [root, trash, outside] { try? FileManager.default.removeItem(at: url) } }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: root.appendingPathComponent(".git/config"))
        try Data("outside".utf8).write(to: outside.appendingPathComponent("keep.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("external"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("metadata"), withDestinationURL: root.appendingPathComponent(".git"))
        let files = deletionFiles(root: root, trash: trash)
        for path in ["", ".", "..", "folder/..", ".git", ".git/config", "metadata/config"] {
            await #expect(throws: ProjectFileError.protectedItem) { try await files.trash(path) }
        }
        for path in [outside.path + "/keep.txt", "external/keep.txt"] {
            await #expect(throws: ProjectFileError.outsideProject) { try await files.trash(path) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
        #expect(try String(contentsOf: outside.appendingPathComponent("keep.txt"), encoding: .utf8) == "outside")
        #expect(try String(contentsOf: root.appendingPathComponent(".git/config"), encoding: .utf8) == "keep")
    }

    @Test func symlinksMoveTheLinkRatherThanTheirTargetsIncludingDanglingLinks() async throws {
        let root = try deletionFolder(), trash = try deletionFolder(), outside = try deletionFolder()
        defer { for url in [root, trash, outside] { try? FileManager.default.removeItem(at: url) } }
        let external = outside.appendingPathComponent("outside.txt"), internalFile = root.appendingPathComponent("inside.txt")
        try Data("outside".utf8).write(to: external)
        try Data("inside".utf8).write(to: internalFile)
        for (name, target) in [("outside-link", external), ("inside-link", internalFile), ("broken-link", outside.appendingPathComponent("missing"))] {
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(name), withDestinationURL: target)
        }
        let files = deletionFiles(root: root, trash: trash)
        for path in ["outside-link", "inside-link", "broken-link"] {
            let moved = try #require(try await files.trash(path))
            #expect(try FileManager.default.attributesOfItem(atPath: moved.path)[.type] as? FileAttributeType == .typeSymbolicLink)
        }
        #expect(try String(contentsOf: external, encoding: .utf8) == "outside")
        #expect(try String(contentsOf: internalFile, encoding: .utf8) == "inside")
        #expect(try await files.entries().map(\.name) == ["inside.txt"])
    }

    @Test func unsupportedRemoteTrashCannotDeleteTheLocalCache() async throws {
        let cache = try deletionFolder()
        defer { try? FileManager.default.removeItem(at: cache) }
        try Data("cached".utf8).write(to: cache.appendingPathComponent("file.txt"))
        let files = RemoteFiles(runtime: WorkspaceRuntime(kind: .ssh, target: "not-connected", directory: "/workspace"), cache: cache, environment: [:])
        #expect(!files.supportsTrash)
        await #expect(throws: ProjectFileError.trashUnavailable) { try await files.trash("file.txt") }
        #expect(try String(contentsOf: cache.appendingPathComponent("file.txt"), encoding: .utf8) == "cached")
    }
}

@MainActor struct WorkspaceDeletionTests {
    @Test func folderDeletionClosesCleanTabsAndPrunesNavigationWithoutAffectingSiblings() async throws {
        let root = try deletionFolder(), trash = try deletionFolder()
        defer { for url in [root, trash] { try? FileManager.default.removeItem(at: url) } }
        for name in ["folder", "folder-sibling"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            try Data(name.utf8).write(to: root.appendingPathComponent(name + "/file.txt"))
        }
        let editor = CodeWorkspace(root: root, files: deletionFiles(root: root, trash: trash))
        await editor.open("folder/file.txt")
        await editor.open("folder-sibling/file.txt")
        await editor.open("folder/file.txt")
        await editor.loadFileIndex()
        var changed = 0
        editor.onSave = { changed += 1 }
        #expect(await editor.moveToTrash("folder"))
        #expect(changed == 1)
        #expect(editor.documents.map(\.path) == ["folder-sibling/file.txt"])
        #expect(editor.savedFiles.map(\.path) == ["folder-sibling/file.txt"])
        #expect(editor.filePaths == ["folder-sibling/file.txt"])
        #expect(!editor.expandedDirectories.contains("folder") && editor.directories["folder"] == nil)
        #expect(!editor.recentFilePaths.contains("folder/file.txt"))
        editor.goBack(); editor.goForward()
        #expect(editor.selectedDocument?.path == "folder-sibling/file.txt")
    }

    @Test func deletingDirtyFilesKeepsDraftsThroughRestartAndAllowsSavingACopy() async throws {
        let root = try deletionFolder(), trash = try deletionFolder()
        defer { for url in [root, trash] { try? FileManager.default.removeItem(at: url) } }
        try Data("saved".utf8).write(to: root.appendingPathComponent("file.txt"))
        let editor = CodeWorkspace(root: root, files: deletionFiles(root: root, trash: trash))
        await editor.open("file.txt")
        let document = try #require(editor.selectedDocument)
        document.text = "my unsaved changes"
        #expect(await editor.moveToTrash("file.txt"))
        #expect(document.text == "my unsaved changes" && document.isModified && document.changedOnDisk && document.isRecoveredDraft)
        #expect(try String(contentsOf: trash.appendingPathComponent("file.txt"), encoding: .utf8) == "saved")
        var layout = ProjectLayout(); layout.files = editor.savedFiles; layout.selectedFile = "file.txt"
        let restored = CodeWorkspace(root: root)
        await restored.restore(layout)
        let draft = try #require(restored.selectedDocument)
        #expect(draft.text == "my unsaved changes" && draft.isRecoveredDraft)
        #expect(await restored.save(draft) == false)
        #expect(await restored.saveCopy(draft, to: root.appendingPathComponent("copy.txt")))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("file.txt").path))
    }

    @Test func aTrashFailureLeavesTheTreeBuffersAndHistoryIntact() async throws {
        let root = try deletionFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("saved".utf8).write(to: root.appendingPathComponent("file.txt"))
        let files = ProjectFiles(root: root) { _ in throw CocoaError(.fileWriteNoPermission) }
        let editor = CodeWorkspace(root: root, files: files)
        await editor.open("file.txt"); await editor.loadFileIndex()
        let document = try #require(editor.selectedDocument)
        document.text = "unsaved"
        let paths = editor.filePaths, entries = editor.visibleEntries.map(\.id)
        #expect(await editor.moveToTrash("file.txt") == false)
        #expect(editor.selectedDocument === document && document.text == "unsaved" && !document.changedOnDisk)
        #expect(editor.filePaths == paths && editor.visibleEntries.map(\.id) == entries)
        #expect(editor.errorMessage?.contains("Couldn't move") == true)
        #expect(editor.trashingPath == nil)
        #expect(try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8) == "saved")
    }

    @Test func editsMadeWhileTrashIsPendingAreKeptAndSavesCannotRecreateTheFile() async throws {
        let root = try deletionFolder(), trash = try deletionFolder()
        defer { for url in [root, trash] { try? FileManager.default.removeItem(at: url) } }
        try Data("saved".utf8).write(to: root.appendingPathComponent("file.txt"))
        let files = DelayedDeletionFiles(backing: deletionFiles(root: root, trash: trash), holdTrash: true)
        let editor = CodeWorkspace(root: root, files: files)
        await editor.open("file.txt")
        let document = try #require(editor.selectedDocument)
        let task = Task { await editor.moveToTrash("file.txt") }
        for _ in 0..<100 { if await files.trashStarted { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(editor.trashingPath == "file.txt")
        document.text = "typed during deletion"
        #expect(await editor.save(document) == false)
        await files.releaseTrash()
        #expect(await task.value)
        #expect(document.text == "typed during deletion" && document.isRecoveredDraft)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("file.txt").path))
    }

    @Test func anIndexStartedBeforeDeletionCannotResurrectTheDeletedPath() async throws {
        let root = try deletionFolder(), trash = try deletionFolder()
        defer { for url in [root, trash] { try? FileManager.default.removeItem(at: url) } }
        try Data("saved".utf8).write(to: root.appendingPathComponent("file.txt"))
        let files = DelayedDeletionFiles(backing: deletionFiles(root: root, trash: trash), holdIndex: true)
        let editor = CodeWorkspace(root: root, files: files)
        let indexing = Task { await editor.loadFileIndex() }
        for _ in 0..<100 { if await files.indexStarted { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await editor.moveToTrash("file.txt"))
        await files.releaseIndex()
        await indexing.value
        #expect(!editor.filePaths.contains("file.txt"))
        await editor.loadFileIndex()
        #expect(editor.filePaths.isEmpty)
    }
}

private actor DelayedDeletionFiles: WorkspaceFiles {
    nonisolated var supportsTrash: Bool { true }
    let backing: ProjectFiles
    var holdTrash: Bool
    var holdIndex: Bool
    var trashStarted = false
    var indexStarted = false
    private var trashGate: CheckedContinuation<Void, Never>?
    private var indexGate: CheckedContinuation<Void, Never>?
    init(backing: ProjectFiles, holdTrash: Bool = false, holdIndex: Bool = false) {
        self.backing = backing; self.holdTrash = holdTrash; self.holdIndex = holdIndex
    }
    func entries(in path: String) async throws -> [ProjectFileEntry] { try await backing.entries(in: path) }
    func filePaths(limit: Int) async throws -> [String] {
        let paths = try await backing.filePaths(limit: limit)
        if holdIndex {
            holdIndex = false; indexStarted = true
            await withCheckedContinuation { indexGate = $0 }
        }
        return paths
    }
    func open(_ path: String) async throws -> ProjectFileContent { try await backing.open(path) }
    func read(_ path: String) async throws -> TextFileSnapshot { try await backing.read(path) }
    func preview(_ path: String) async throws -> FilePreviewSnapshot { try await backing.preview(path) }
    func write(_ text: String, replacing snapshot: TextFileSnapshot, overwrite: Bool) async throws -> TextFileSnapshot {
        try await backing.write(text, replacing: snapshot, overwrite: overwrite)
    }
    func trash(_ path: String) async throws -> URL? {
        if holdTrash { trashStarted = true; await withCheckedContinuation { trashGate = $0 } }
        return try await backing.trash(path)
    }
    func releaseTrash() { trashGate?.resume(); trashGate = nil }
    func releaseIndex() { indexGate?.resume(); indexGate = nil }
}
