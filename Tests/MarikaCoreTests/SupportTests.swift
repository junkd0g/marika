import Foundation
import Testing

@testable import MarikaCore

struct JSONValueTests {
    @Test func integersSurviveARoundTrip() throws {
        // Tool inputs go back to the CLI, and `120000.0` could fail its validation.
        let value = try JSONValue(parsing: Data(#"{"timeout":120000,"ratio":0.5,"on":true,"none":null}"#.utf8))
        let again = try JSONValue(parsing: value.serialized())
        #expect(again == value)
        #expect(value["timeout"] == .int(120000))
        #expect(value["on"] == .bool(true))
        #expect(String(decoding: try JSONValue.int(120000).serialized(), as: UTF8.self) == "120000")
    }

    @Test func codableMatchesTheWireFormat() throws {
        let value: JSONValue = ["a": [1, "two", nil, true], "b": ["c": 1.5]]
        let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
    }
}

struct DiffParserTests {
    private let gitOutput = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1234567..89abcde 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -10,3 +10,4 @@ struct App {
         let a = 1
        -let b = 2
        +let b = 3
        +let c = 4
         let d = 5
        @@ -40,2 +41,1 @@
        -gone
         kept
        diff --git a/old.txt b/new.txt
        similarity index 100%
        rename from old.txt
        rename to new.txt
        diff --git a/image.png b/image.png
        Binary files a/image.png and b/image.png differ

        """

    @Test func parsesMultipleFiles() {
        let files = DiffParser.parse(gitOutput)
        #expect(files.map(\.path) == ["Sources/App.swift", "new.txt", "image.png"])
        #expect(files[2].isBinary)
    }

    @Test func tracksLineNumbersAcrossHunks() throws {
        let file = try #require(DiffParser.parse(gitOutput).first)
        #expect(file.additions == 2)
        #expect(file.deletions == 2)
        let added = try #require(file.lines.first { $0.text == "let c = 4" })
        #expect(added.newNumber == 12)
        #expect(added.oldNumber == nil)
        let kept = try #require(file.lines.first { $0.text == "kept" })
        #expect(kept.oldNumber == 41)
        #expect(kept.newNumber == 41)
        #expect(file.lines.contains { $0.kind == .hunk })
    }

    @Test func aBareHunkUsesTheDefaultPath() {
        let files = DiffParser.parse("@@ -1 +1 @@\n-old\n+new\n", defaultPath: "a.txt")
        #expect(files.first?.path == "a.txt")
        #expect(files.first?.additions == 1)
    }

    @Test func crlfFilesParseLineByLine() {
        let files = DiffParser.parse("@@ -1,3 +1,3 @@\n alpha\r\n-beta\r\n+BETA\r\n gamma\r\n", defaultPath: "a.txt")
        #expect(files.first?.additions == 1)
        #expect(files.first?.deletions == 1)
        #expect(files.first?.lines.map(\.text) == ["alpha", "beta", "BETA", "gamma"])
    }

    @Test func crlfContentHasNoStrayCarriageReturns() {
        #expect(DiffFile(path: "a", newContent: "one\r\ntwo\r\n").lines.map(\.text) == ["one", "two"])
    }

    @Test func removedLinesThatLookLikeHeadersStayInTheBody() {
        let files = DiffParser.parse("@@ -1,2 +1,1 @@\n--- not a header\n+++ also not\n", defaultPath: "a.txt")
        #expect(files.first?.deletions == 1)
        #expect(files.first?.additions == 1)
    }
}

struct PreviewTests {
    @Test func unchangedAnchorLinesBecomeContext() {
        let file = DiffFile(
            path: "a.py", replacing: "keep\n\nif x:\n", with: "keep\n\ndef new():\n    pass\n\nif x:\n")
        #expect(file.deletions == 0)
        #expect(file.additions == 3)
        #expect(file.lines.first { $0.kind == .addition }?.text == "def new():")
        #expect(file.lines.filter { $0.kind == .context }.map(\.text) == ["keep", "", "if x:"])
    }

    @Test func aRewriteStaysARewrite() {
        let file = DiffFile(path: "a.py", replacing: "old\n", with: "new\n")
        #expect(file.deletions == 1)
        #expect(file.additions == 1)
    }

    @Test func repeatedLinesAreNotCountedTwice() {
        let file = DiffFile(path: "a.py", replacing: "x\nx\n", with: "x\n")
        #expect(file.deletions == 1)
        #expect(file.additions == 0)
    }
}

struct AgentLocatorTests {
    private func makeApp(at path: String, in root: URL) throws -> URL {
        let bundle = root.appendingPathComponent("Some Folder/ChatGPT.app")
        let binary = bundle.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return bundle
    }

    @Test func findsCodexInsideTheDesktopApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeApp(at: "Contents/Resources/codex-cli/bin/codex", in: root)
        let found = AgentLocator.locate(.codex, in: ["PATH": "/nonexistent", "HOME": root.path], appBundles: [bundle])
        #expect(found?.path.hasSuffix("codex-cli/bin/codex") == true)
    }

    @Test func aCLIOnThePathWinsOverTheApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeApp(at: "Contents/Resources/codex-cli/bin/codex", in: root)
        let tools = root.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let onPath = tools.appendingPathComponent("codex")
        try "#!/bin/sh\n".write(to: onPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: onPath.path)
        let found = AgentLocator.locate(.codex, in: ["PATH": tools.path, "HOME": root.path], appBundles: [bundle])
        #expect(found?.standardizedFileURL == onPath.standardizedFileURL)
    }

    @Test func claudeIsNeverLookedForInsideOtherApps() {
        #expect(AgentLocator.locate(.claude, in: ["PATH": "/nonexistent", "HOME": "/nonexistent"]) == nil)
    }
}

struct FileLinkTests {
    private let root = URL(fileURLWithPath: "/work/app")

    @Test func absoluteLinksKeepTheirPathAndDropThePosition() throws {
        let url = try #require(URL(string: "/work/app/src/a.py:12"))
        #expect(FilePath.linkTarget(url, relativeTo: root)?.path == "/work/app/src/a.py")
        let withColumn = try #require(URL(string: "/work/app/src/a.py:12:3"))
        #expect(FilePath.linkTarget(withColumn, relativeTo: root)?.path == "/work/app/src/a.py")
    }

    @Test func relativeLinksResolveInsideTheProject() throws {
        let url = try #require(URL(string: "src/a.py#L12"))
        #expect(FilePath.linkTarget(url, relativeTo: root)?.path == "/work/app/src/a.py")
    }

    @Test func webLinksAreNotFiles() throws {
        let url = try #require(URL(string: "https://example.com/a.py"))
        #expect(FilePath.linkTarget(url, relativeTo: root) == nil)
    }

    @Test func customSchemesAreNotFiles() throws {
        let url = try #require(URL(string: "x-danger://run?cmd=rm"))
        #expect(FilePath.linkTarget(url, relativeTo: root) == nil)
    }
}

struct PathTests {
    @Test func projectPathsAreShortened() {
        #expect(ToolDescriber.relative("/work/app/src/a.swift", to: "/work/app") == "src/a.swift")
        #expect(ToolDescriber.relative("/work/app/src/a.swift", to: "/work/app/") == "src/a.swift")
    }

    @Test func siblingFoldersAreLeftAlone() {
        #expect(ToolDescriber.relative("/work/app-old/a.swift", to: "/work/app") == "/work/app-old/a.swift")
    }

    @Test func filesOutsideTheProjectUseTilde() {
        let inside = NSHomeDirectory() + "/.claude/plans/a.md"
        #expect(ToolDescriber.relative(inside, to: "/work/app") == "~/.claude/plans/a.md")
    }

    @Test func resolvedSpellingsMatch() {
        // On macOS /tmp is a symlink, and agents report the /private path.
        #expect(ToolDescriber.relative("/private/tmp/a.txt", to: "/tmp") == "a.txt")
    }
}

struct ShellEnvironmentTests {
    @Test func ignoresBannersBeforeTheMarker() throws {
        var data = Data("Welcome to my shell!\n".utf8)
        data.append(Data("__MARIKA_ENV_BEGIN__\0PATH=/opt/homebrew/bin:/usr/bin\0EQ=a=b\0EMPTY=\0".utf8))
        let environment = try #require(ShellEnvironment.parse(data))
        #expect(environment["PATH"] == "/opt/homebrew/bin:/usr/bin")
        #expect(environment["EQ"] == "a=b")
        #expect(environment["EMPTY"] == "")
    }

    @Test func capturesTheRealLoginShell() async {
        let environment = await ShellEnvironment.capture()
        #expect(environment["PATH"]?.contains("/usr/bin") == true)
        #expect(environment["HOME"] != nil)
        #expect(environment["CLAUDECODE"] == nil, "variables from whatever launched the app must not leak in")
    }
}

struct GitParsingTests {
    @Test func parsesPorcelainStatus() {
        let output = " M Sources/a.swift\0A  added.txt\0R  new.txt\0old.txt\0?? notes.md\0D  gone.txt\0UU clash.txt\0"
        let changes = Git.parseStatus(output)
        let byPath = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0.status) })
        #expect(byPath["Sources/a.swift"] == .modified)
        #expect(byPath["added.txt"] == .added)
        #expect(byPath["new.txt"] == .renamed)
        #expect(byPath["old.txt"] == nil, "the old side of a rename is not a change of its own")
        #expect(byPath["notes.md"] == .untracked)
        #expect(byPath["gone.txt"] == .deleted)
        #expect(byPath["clash.txt"] == .conflicted)
    }

    @Test func parsesNumstatIncludingRenames() {
        let output = "3\t1\tSources/a.swift\0" + "0\t0\t\0old.txt\0new.txt\0" + "-\t-\timage.png\0"
        let counts = Git.parseNumstat(output)
        #expect(counts["Sources/a.swift"]?.additions == 3)
        #expect(counts["Sources/a.swift"]?.deletions == 1)
        #expect(counts["new.txt"] != nil)
        #expect(counts["image.png"]?.additions == 0)
    }
}

@MainActor
struct SessionControllerTests {
    private func makeController() -> SessionController {
        SessionController(meta: SessionMeta(projectID: UUID(), agent: .claude)) { _ in IdleAgent() }
    }

    @Test func deltasAreBatchedThenFinalised() {
        let session = makeController()
        session.apply(.textDelta(id: "a", delta: "Hel", parentToolID: nil))
        session.apply(.textDelta(id: "a", delta: "lo", parentToolID: nil))
        session.flushDeltas()
        #expect(session.assistantText == ["Hello"])
        session.apply(.textFinished(id: "a", text: "Hello!", parentToolID: nil))
        #expect(session.assistantText == ["Hello!"])
    }

    @Test func anEventAfterADeltaCannotOvertakeIt() {
        let session = makeController()
        session.apply(.textDelta(id: "a", delta: "first", parentToolID: nil))
        session.apply(.tool(ToolCall(id: "t", name: "Bash", kind: .shell, title: "Run", detail: "ls")))
        guard case .assistant = session.items[0].content, case .tool = session.items[1].content else {
            Issue.record("items out of order")
            return
        }
    }

    @Test func retryNoticesCollapseAndClear() {
        let session = makeController()
        session.apply(.notice(Notice(level: .warning, text: "attempt 1", key: "retry")))
        session.apply(.notice(Notice(level: .warning, text: "attempt 2", key: "retry")))
        #expect(session.notices.map(\.text) == ["attempt 2"])
        session.apply(.textFinished(id: "a", text: "ok", parentToolID: nil))
        #expect(session.notices.isEmpty)
        #expect(session.assistantText == ["ok"], "the index must survive the removal")
        session.apply(.textFinished(id: "a", text: "still ok", parentToolID: nil))
        #expect(session.assistantText == ["still ok"])
    }

    @Test func openToolsAreCancelledWhenATurnIsStopped() {
        let session = makeController()
        session.apply(.tool(ToolCall(id: "t", name: "Bash", kind: .shell, title: "Run", detail: "sleep")))
        session.apply(.turnFinished(TurnSummary(outcome: .interrupted)))
        #expect(session.tools.first?.status == .cancelled)
    }

    @Test func backgroundWorkKeepsRunningAfterACompletedTurn() {
        let session = makeController()
        session.apply(.tool(ToolCall(id: "t", name: "shell", kind: .shell, title: "Run", detail: "npm run dev")))
        session.apply(.turnFinished(TurnSummary(outcome: .completed)))
        #expect(session.tools.first?.status == .running, "the process really is still running")
        session.apply(.toolFinished(id: "t", output: "bg-done", status: .succeeded, diff: []))
        #expect(session.tools.first?.status == .succeeded)
    }

    @Test func aRetractedPartialAnswerDisappears() {
        let session = makeController()
        session.apply(.textDelta(id: "a", delta: "half an ans", parentToolID: nil))
        session.apply(.itemRetracted(id: "a"))
        session.apply(.textFinished(id: "b", text: "whole answer", parentToolID: nil))
        #expect(session.assistantText == ["whole answer"])
    }

    @Test func aCancelledApprovalDoesNotLeaveTheSessionWaiting() {
        let session = makeController()
        session.apply(.phaseChanged(.running))
        session.apply(.approvalRequested(ApprovalRequest(id: "r", title: "Run?")))
        session.apply(.approvalCancelled(id: "r"))
        #expect(session.phase == .running)
    }

    @Test func approvalsPauseAndResumeTheSession() {
        let session = makeController()
        let request = ApprovalRequest(id: "r", title: "Run?")
        session.apply(.phaseChanged(.running))
        session.apply(.approvalRequested(request))
        #expect(session.phase == .waitingForUser)
        session.answer(request, with: .allow())
        #expect(session.phase == .running)
        #expect(session.approvals.isEmpty)
    }

    @Test func transcriptsLoadedFromDiskHaveNothingInFlight() {
        let running = ToolCall(id: "t", name: "Bash", kind: .shell, title: "Run", detail: "sleep")
        let session = SessionController(
            meta: SessionMeta(projectID: UUID(), agent: .claude),
            items: [TranscriptItem(id: "t", content: .tool(running))]
        ) { _ in IdleAgent() }
        #expect(session.tools.first?.status == .cancelled)
    }

    @Test func titlesComeFromTheFirstMessage() {
        let session = makeController()
        session.send(UserInput(text: "\n  Fix the login bug  \nand add a test"))
        #expect(session.meta.title == "Fix the login bug")
        session.send(UserInput(text: "Something else"))
        #expect(session.meta.title == "Fix the login bug")
    }

    @Test func draftEditsSaveMetadataWithoutStartingATurnOrChangingRecency() {
        let session = makeController()
        let updatedAt = session.meta.updatedAt
        var drafts: [SessionDraft?] = []
        session.onDraftChange = { drafts.append($0.meta.draft) }
        session.onChange = { _ in Issue.record("Draft edits should not dirty the transcript") }

        session.draft = "  Fix this\nwhen ready  "
        let image = ImageAttachment(path: "/tmp/reference.png", mediaType: "image/png")
        session.draftImages.append(image)
        session.draft = session.draft

        #expect(drafts.count == 2, "Assigning an unchanged draft should not schedule another save")
        #expect(session.meta.draft == SessionDraft(text: "  Fix this\nwhen ready  ", images: [image]))
        #expect(session.meta.updatedAt == updatedAt)
        #expect(session.items.isEmpty)
        #expect(session.phase == .idle)

        session.draft = ""
        #expect(session.meta.hasDraft, "An image on its own is still a draft")
        session.draftImages.removeAll()
        #expect(session.meta.draft == nil)
        #expect(!session.meta.hasDraft)
    }
}

struct StoreTests {
    @Test @MainActor func draftsSurviveRelaunchAndStayClearedAfterSending() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root)
        let project = Project(path: "/tmp/demo")
        let image = ImageAttachment(path: store.attachmentsDirectory.appendingPathComponent("reference.png").path, mediaType: "image/png")
        let draft = SessionDraft(text: "Review this screenshot\nKeep the spacing", images: [image])
        let meta = SessionMeta(projectID: project.id, agent: .claude, draft: draft)
        try await store.save(Workspace(projects: [project], sessions: [meta]))

        let reloaded = try #require(try await store.loadWorkspace().sessions.first)
        let session = SessionController(meta: reloaded) { _ in IdleAgent() }
        #expect(session.draft == draft.text)
        #expect(session.draftImages == [image])
        session.send(UserInput(text: session.draft, images: session.draftImages))
        session.draft = ""
        session.draftImages = []
        try await store.save(Workspace(projects: [project], sessions: [session.meta]))
        let afterSend = try #require(try await store.loadWorkspace().sessions.first)
        #expect(afterSend.draft == nil)
        #expect(!afterSend.hasDraft)
    }

    @Test func sessionsSavedBeforeDraftSupportStillLoad() throws {
        let meta = SessionMeta(projectID: UUID(), agent: .codex)
        let encoder = JSONEncoder()
        let data = try encoder.encode(meta)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "draft")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let loaded = try JSONDecoder().decode(SessionMeta.self, from: legacyData)
        #expect(loaded == meta)
        #expect(!loaded.hasDraft)
    }

    @Test func workspaceAndTranscriptsRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root)

        let project = Project(path: "/tmp/demo")
        let meta = SessionMeta(projectID: project.id, agent: .codex, title: "Demo", conversationID: "abc", mode: .plan)
        try await store.save(Workspace(projects: [project], sessions: [meta]))

        let call = ToolCall(
            id: "t", name: "Bash", kind: .shell, title: "Run", detail: "ls", input: ["timeout": 120000], status: .succeeded)
        let items = [
            TranscriptItem(id: "1", content: .user(text: "hi", images: [])),
            TranscriptItem(id: "t", content: .tool(call)),
            TranscriptItem(id: "2", content: .turnEnd(TurnSummary(outcome: .completed, durationMs: 1200))),
        ]
        try await store.saveTranscript(items, for: meta.id)

        let loaded = try await store.loadWorkspace()
        #expect(loaded.projects == [project])
        #expect(loaded.sessions.first?.conversationID == "abc")
        #expect(loaded.sessions.first?.mode == .plan)
        #expect(try await store.loadTranscript(meta.id).count == 3)
    }

    @Test func aMissingWorkspaceStartsEmptyButCorruptDataIsProtected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root)
        #expect(try await store.loadWorkspace() == Workspace())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("workspace.json")
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: file)
        await #expect(throws: StoreError.self) { try await store.loadWorkspace() }
        await #expect(throws: StoreError.self) { try await store.save(Workspace()) }
        #expect(try Data(contentsOf: file) == corrupt)
    }
}
