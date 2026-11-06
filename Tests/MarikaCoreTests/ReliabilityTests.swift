import Darwin
import Foundation
import Testing
@testable import MarikaCore

private func reliabilityFolder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("marika-reliability-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.resolvingSymlinksInPath()
}

@MainActor struct DraftRecoveryTests {
    @Test func deletedFilesKeepDraftsAcrossRepeatedRestartsAndRequireExplicitOverwrite() async throws {
        let root = try reliabilityFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        var layout = ProjectLayout()
        layout.files = [EditorFileState(path: "deleted.swift", draft: "valuable draft", baseText: "old content")]
        layout.selectedFile = "deleted.swift"
        let first = CodeWorkspace(root: root)
        await first.restore(layout)
        let recovered = try #require(first.selectedDocument)
        #expect(recovered.isModified && recovered.isEditable && recovered.changedOnDisk && recovered.isRecoveredDraft)
        await first.refresh()
        #expect(recovered.text == "valuable draft" && recovered.changedOnDisk)
        #expect(await first.save(recovered) == false)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(recovered.path).path))
        layout.files = first.savedFiles
        let second = CodeWorkspace(root: root)
        await second.restore(layout)
        let again = try #require(second.selectedDocument)
        #expect(again.text == "valuable draft")
        #expect(await second.save(again, overwrite: true))
        #expect(!again.isRecoveredDraft && !again.isModified)
        #expect(try String(contentsOf: root.appendingPathComponent(again.path), encoding: .utf8) == "valuable draft")
    }

    @Test func binaryReplacementsAndEmptyDraftsArePreservedAndCanBeCopied() async throws {
        let root = try reliabilityFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = Data([0, 1, 2])
        try binary.write(to: root.appendingPathComponent("replaced.txt"))
        var layout = ProjectLayout()
        layout.files = [EditorFileState(path: "replaced.txt", draft: "", baseText: ""),
                        EditorFileState(path: "../outside.txt", draft: "keep me", baseText: "old")]
        layout.selectedFile = "replaced.txt"
        let editor = CodeWorkspace(root: root)
        await editor.restore(layout)
        let empty = try #require(editor.selectedDocument)
        #expect(empty.isEditable && empty.isModified && empty.isRecoveredDraft)
        #expect(editor.savedFiles.first?.draft == "")
        let copy = root.appendingPathComponent("copy.txt")
        #expect(await editor.saveCopy(empty, to: copy))
        #expect(try Data(contentsOf: copy).isEmpty)
        #expect(try Data(contentsOf: root.appendingPathComponent("replaced.txt")) == binary)
        let outside = try #require(editor.documents.first { $0.path == "../outside.txt" })
        #expect(await editor.save(outside, overwrite: true) == false)
        #expect(outside.text == "keep me" && outside.isModified)
    }
}

struct StoreRecoveryTests {
    @Test func corruptWorkspaceRecoversLastGoodBackupAndKeepsDamagedOriginal() async throws {
        let root = try reliabilityFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root)
        let first = Workspace(projects: [Project(path: "/first")])
        let second = Workspace(projects: [Project(path: "/second")])
        try await store.save(first)
        try await store.save(second)
        let damaged = Data("broken workspace".utf8)
        try damaged.write(to: root.appendingPathComponent("workspace.json"))
        #expect(try await store.loadWorkspace() == first)
        #expect(await store.takeRecoveryNotices().count == 1)
        let kept = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("corrupt-") }
        #expect(kept.count == 1)
        #expect(try Data(contentsOf: #require(kept.first)) == damaged)
        try await store.save(second)
        #expect(try await store.loadWorkspace() == second)
    }

    @Test func failedWritesAreReportedAndCanBeRetriedWithoutLosingTheBackup() async throws {
        let parent = try reliabilityFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("data")
        try Data("blocking file".utf8).write(to: root)
        let store = Store(root: root)
        let workspace = Workspace(projects: [Project(path: "/valuable")])
        await #expect(throws: StoreError.self) { try await store.save(workspace) }
        try FileManager.default.removeItem(at: root)
        try await store.save(workspace)
        #expect(try await store.loadWorkspace() == workspace)
        let backup = try Data(contentsOf: root.appendingPathComponent("workspace.json.bak"))
        try Data("corrupt".utf8).write(to: root.appendingPathComponent("workspace.json"))
        await #expect(throws: StoreError.self) { try await store.save(Workspace()) }
        #expect(try Data(contentsOf: root.appendingPathComponent("workspace.json.bak")) == backup)
        try await store.retryFailedSaves()
        #expect(try await store.loadWorkspace() == workspace)
        try await store.save(workspace)
    }

    @Test func transcriptRecoveryAndDeletionHandleBackupsToo() async throws {
        let root = try reliabilityFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root), id = UUID()
        let items = [TranscriptItem(id: "draft", content: .user(text: "keep this", images: []))]
        try await store.saveTranscript(items, for: id)
        let file = root.appendingPathComponent("transcripts/\(id.uuidString).json")
        try Data("corrupt".utf8).write(to: file)
        #expect(try await store.loadTranscript(id).first?.id == "draft")
        await store.deleteTranscript(id)
        #expect(try await store.loadTranscript(id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.appendingPathExtension("bak").path))
    }
}

struct ProjectConfigTrustTests {
    @Test func changedContentsAndNewFilesNeedTrustEvenWhenFilenamesAreAlreadyKnown() throws {
        let root = try reliabilityFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent(".claude/settings.json")
        try Data("{\"hook\":\"one\"}".utf8).write(to: file)
        let accepted = try ProjectConfigTrust.snapshot(from: root)
        #expect(ProjectConfigTrust.changedFiles(in: accepted, accepted: accepted).isEmpty)
        #expect(ProjectConfigTrust.changedFiles(in: accepted, accepted: nil).contains(file.path))
        try Data("{\"hook\":\"two\"}".utf8).write(to: file)
        #expect(ProjectConfigTrust.changedFiles(in: try ProjectConfigTrust.snapshot(from: root), accepted: accepted) == [file.path])
        let newFile = root.appendingPathComponent(".mcp.json")
        try Data("{}".utf8).write(to: newFile)
        #expect(ProjectConfigTrust.changedFiles(in: try ProjectConfigTrust.snapshot(from: root), accepted: accepted).contains(newFile.path))
    }

    @Test func ancestorMCPAndMainCheckoutSettingsAreIncludedForLinkedWorktrees() throws {
        let root = try reliabilityFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main")
        let linked = root.appendingPathComponent("linked")
        let gitdir = main.appendingPathComponent(".git/worktrees/linked")
        for directory in [gitdir, main.appendingPathComponent(".claude"), linked] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("gitdir: \(gitdir.path)\n".utf8).write(to: linked.appendingPathComponent(".git"))
        try Data("../..\n".utf8).write(to: gitdir.appendingPathComponent("commondir"))
        try Data("{}".utf8).write(to: root.appendingPathComponent(".mcp.json"))
        let settings = main.appendingPathComponent(".claude/settings.json")
        try Data("{}".utf8).write(to: settings)
        let snapshot = try ProjectConfigTrust.snapshot(from: linked)
        #expect(snapshot[root.appendingPathComponent(".mcp.json").path] != nil)
        #expect(snapshot[settings.path] != nil)
    }

    @Test func oldTrustRecordsDoNotBypassContentChecks() throws {
        let data = Data(#"{"path":"/demo","name":"Demo","id":"00000000-0000-0000-0000-000000000001","acceptedConfigFiles":["/demo/.mcp.json"]}"#.utf8)
        let legacy = try JSONDecoder().decode(Project.self, from: data)
        #expect(legacy.acceptedConfigDigests == nil)
        #expect(ProjectConfigTrust.changedFiles(in: ["/demo/.mcp.json": "digest"], accepted: legacy.acceptedConfigDigests) == ["/demo/.mcp.json"])
    }

    @Test func nonregularAndOversizedConfigurationCannotBlockTrustChecks() throws {
        let root = try reliabilityFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".mcp.json")
        #expect(mkfifo(file.path, 0o600) == 0)
        #expect(throws: AgentError.self) { try ProjectConfigTrust.snapshot(from: root) }
        try FileManager.default.removeItem(at: file)
        try Data(repeating: 65, count: 2 * 1024 * 1024 + 1).write(to: file)
        #expect(throws: AgentError.self) { try ProjectConfigTrust.snapshot(from: root) }
    }
}

struct CommandReliabilityTests {
    @Test func ignoredTerminationIsForcedAndDescendantsCannotKeepRunning() async throws {
        let root = try reliabilityFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("survived")
        let start = Date()
        let result = try await Command.run(URL(fileURLWithPath: "/bin/sh"),
            ["-c", "trap '' TERM; (sleep 2; touch survived) & wait"], workingDirectory: root, timeout: 0.2)
        #expect(result.timedOut && !result.succeeded)
        #expect(Date().timeIntervalSince(start) < 1.8)
        try await Task.sleep(for: .seconds(2.1))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func cancellationStopsTheCommandAndThrowsCancellationError() async throws {
        let task = Task {
            try await Command.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "trap '' TERM; sleep 30"], timeout: 30)
        }
        try await Task.sleep(for: .milliseconds(100))
        let start = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(start) < 2)
        let subsequent = try await Command.run(URL(fileURLWithPath: "/bin/echo"), ["still works"])
        #expect(subsequent.succeeded && subsequent.output == "still works\n")
    }

    @Test func largeOutputsDrainBothPipesAndLaunchFailuresAreReported() async throws {
        let result = try await Command.run(URL(fileURLWithPath: "/usr/bin/python3"),
            ["-c", "import sys; sys.stdout.write('a'*200000); sys.stdout.flush(); sys.stderr.write('b'*200000)"])
        #expect(result.succeeded && !result.timedOut)
        #expect(result.stdout.count == 200_000 && result.stderr.count == 200_000)
        await #expect(throws: POSIXError.self) {
            try await Command.run(URL(fileURLWithPath: "/does-not-exist-marika"), [])
        }
    }
}

struct GitSafetyTests {
    private func git(_ args: [String], root: URL) async throws {
        let result = try await Command.run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", root.path] + args,
            environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
        #expect(result.succeeded, "\(result.errorOutput)")
    }

    @Test func repositoryHelpersAndInjectedEnvironmentNeverExecuteDuringInspection() async throws {
        let root = try reliabilityFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try await git(["init", "-b", "main"], root: root)
        try Data("before\n".utf8).write(to: root.appendingPathComponent("sample.txt"))
        try Data("sample.txt diff=evil\n".utf8).write(to: root.appendingPathComponent(".gitattributes"))
        try await git(["add", "."], root: root)
        try await git(["-c", "user.name=Test", "-c", "user.email=test@local", "-c", "commit.gpgsign=false", "commit", "-m", "Initial"], root: root)
        let script = root.appendingPathComponent("evil.sh")
        try Data("#!/bin/sh\ntouch EXECUTED\ncat \"$1\"\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        for key in ["core.fsmonitor", "diff.evil.textconv", "diff.evil.command"] {
            try await git(["config", key, script.path], root: root)
        }
        try Data("after\n".utf8).write(to: root.appendingPathComponent("sample.txt"))
        let index = root.appendingPathComponent(".git/index")
        let before = try Data(contentsOf: index)
        let inspector = Git(environment: ["GIT_EXTERNAL_DIFF": script.path, "GIT_DIR": "/nonexistent", "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "core.fsmonitor", "GIT_CONFIG_VALUE_0": script.path])
        let snapshot = await inspector.snapshot(at: root)
        #expect(snapshot.isRepository && snapshot.error == nil)
        #expect(snapshot.changes.contains { $0.path == "sample.txt" && $0.additions == 1 && $0.deletions == 1 })
        let diff = await inspector.diff(for: GitChange(path: "sample.txt", status: .modified), at: root)
        #expect(diff.lines.contains { $0.text == "after" && $0.kind == .addition })
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("EXECUTED").path))
        #expect(try Data(contentsOf: index) == before)
    }

    @Test func untrackedSymlinksAndOversizedFilesAreNotRead() async throws {
        let root = try reliabilityFolder(), outside = try reliabilityFolder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try Data("private data".utf8).write(to: outside.appendingPathComponent("secret"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside.appendingPathComponent("secret"))
        try Data(repeating: 65, count: 600_000).write(to: root.appendingPathComponent("large"))
        let inspector = Git(environment: [:])
        for path in ["link", "large", "../outside"] {
            let diff = await inspector.diff(for: GitChange(path: path, status: .untracked), at: root)
            #expect(diff.isBinary && diff.lines.isEmpty)
        }
    }

    @Test func linkedWorktreesAreDiscoveredWithoutTrustingGitEnvironment() async throws {
        let root = try reliabilityFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main"), linked = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try await git(["init", "-b", "main"], root: main)
        try Data("original\n".utf8).write(to: main.appendingPathComponent("a.txt"))
        try await git(["add", "."], root: main)
        try await git(["-c", "user.name=Test", "-c", "user.email=test@local", "-c", "commit.gpgsign=false", "commit", "-m", "Initial"], root: main)
        try await git(["worktree", "add", "-b", "review", linked.path, "HEAD"], root: main)
        try Data("edited\n".utf8).write(to: linked.appendingPathComponent("a.txt"))
        let snapshot = await Git(environment: ["GIT_DIR": "/nonexistent"]).snapshot(at: linked)
        #expect(snapshot.isRepository && snapshot.error == nil && snapshot.branch == "review")
        #expect(snapshot.changes.first?.path == "a.txt" && snapshot.additions == 1 && snapshot.deletions == 1)
    }
}
