import AppKit
import Foundation
import Testing

@testable import MarikaCore

/// Drives the real, signed-in Codex through the real engine, using a small model at low effort.
/// Opt in with: MARIKA_LIVE=1 swift test --filter LiveCodexTests
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MARIKA_LIVE"] != nil), .serialized)
struct LiveCodexTests {
    private static let model = "gpt-6-luna"

    /// A git repository, because Codex treats those as trusted working folders.
    private func makeProject() throws -> URL {
        let url = URL(fileURLWithPath: FilePath.resolved(NSTemporaryDirectory()))
            .appendingPathComponent("marika-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "first line\n".write(to: url.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", url.path, "init", "-q"]
        try git.run()
        git.waitUntilExit()
        return url
    }

    private func makeSession(
        in directory: URL, mode: ApprovalMode = .ask, conversationID: String? = nil
    ) async throws -> SessionController {
        let shell = await ShellEnvironment.capture()
        let executable = try #require(AgentLocator.locate(.codex, in: shell), "Codex should be found")
        let meta = SessionMeta(
            projectID: UUID(), agent: .codex, conversationID: conversationID, model: Self.model, effort: "low", mode: mode)
        return SessionController(meta: meta) { meta in
            CodexSession(
                launch: AgentLaunch(
                    executable: executable, environment: shell, workingDirectory: directory,
                    conversationID: meta.conversationID, settings: meta.settings))
        }
    }

    /// Ends a session and archives its thread, so test runs stay out of the user's Codex history.
    private func finish(_ session: SessionController) async {
        await session.shutdown()
        guard let id = session.meta.conversationID else { return }
        let shell = await ShellEnvironment.capture()
        guard let executable = AgentLocator.locate(.codex, in: shell) else { return }
        let connection = CodexConnection(
            executable: executable, environment: shell, workingDirectory: FileManager.default.temporaryDirectory,
            inbound: { _ in })
        try? await connection.start()
        try? await connection.initialize()
        _ = try? await connection.request("thread/archive", ["threadId": .string(id)])
        await connection.close()
    }

    private func run(
        _ session: SessionController, _ prompt: String, images: [ImageAttachment] = [],
        answer: (ApprovalRequest) -> ApprovalDecision? = { _ in .allow() },
        onRunning: (() -> Void)? = nil
    ) async throws {
        let turnsBefore = session.turnEnds.count
        session.send(UserInput(text: prompt, images: images))
        let deadline = Date().addingTimeInterval(150)
        while Date() < deadline {
            if let request = session.pendingApproval, let decision = answer(request) {
                session.answer(request, with: decision)
            }
            onRunning?()
            if session.turnEnds.count > turnsBefore, !session.isBusy { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("the turn did not finish; phase: \(session.phase), notices: \(session.notices.map(\.text))")
    }

    @Test func statusReadsTheRealAccount() async throws {
        let shell = await ShellEnvironment.capture()
        let executable = try #require(AgentLocator.locate(.codex, in: shell))
        let probe = await CodexCLI.probe(executable: executable, environment: shell)
        #expect(probe.status.readiness == .ready)
        #expect(probe.status.plan?.hasPrefix("ChatGPT") == true)
        #expect(probe.status.version != nil)
        #expect(probe.capabilities?.models.contains { $0.id == Self.model } == true)
        #expect(probe.capabilities?.models.first?.efforts.isEmpty == false)
        #expect(probe.rateLimit != nil)
    }

    // MARK: What each mode promises

    @Test func aSessionDoesNotTrustTheFolder() async throws {
        let project = try makeProject()
        let session = try await makeSession(in: project)
        try await run(session, "Reply with exactly: ok")
        let config = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/config.toml")
        let text = try String(contentsOf: config, encoding: .utf8)
        #expect(!text.contains(project.path), "starting a session must not mark the folder as trusted")
        await finish(session)
    }

    @Test func askFirstAsksEvenForReadOnlyCommands() async throws {
        let project = try makeProject()
        let session = try await makeSession(in: project, mode: .ask)
        var asked = 0
        try await run(session, "Run this exact shell command: ls . Then reply with exactly: done") { _ in
            asked += 1
            return .allow()
        }
        #expect(asked >= 1)
        await finish(session)
    }

    @Test func acceptEditsAppliesEditsButAsksForCommands() async throws {
        let project = try makeProject()
        let session = try await makeSession(in: project, mode: .acceptEdits)
        var commands = 0
        var edits = 0
        try await run(
            session,
            "First use the apply_patch tool to change 'first line' to 'edited line' in notes.txt. Then run this exact shell command: touch ran.txt . Then reply with exactly: done"
        ) { request in
            if request.toolKind == .shell { commands += 1 }
            if request.toolKind == .edit { edits += 1 }
            return .allow()
        }
        let contents = try String(contentsOf: project.appendingPathComponent("notes.txt"), encoding: .utf8)
        #expect(contents.contains("edited line"))
        #expect(edits == 0, "edits in the project should apply without a prompt")
        #expect(commands >= 1, "the label promises commands still ask")
        await finish(session)
    }

    @Test func autoRunsInsideTheProjectWithoutAsking() async throws {
        let project = try makeProject()
        let session = try await makeSession(in: project, mode: .auto)
        var asked = 0
        try await run(session, "Run this exact shell command: touch auto.txt . Then reply with exactly: done") { _ in
            asked += 1
            return .allow()
        }
        #expect(asked == 0)
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("auto.txt").path))
        await finish(session)
    }

    @Test func readOnlyDoesNotChangeFiles() async throws {
        let project = try makeProject()
        let session = try await makeSession(in: project, mode: .plan)
        try await run(session, "Run this exact shell command once: touch blocked.txt . Do not retry. Then reply with exactly: done") { _ in .deny }
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("blocked.txt").path))
        await finish(session)
    }

    @Test func approvedNetworkCommandsWork() async throws {
        let project = try makeProject()
        let session = try await makeSession(in: project, mode: .ask)
        try await run(session, "Run this exact shell command: curl -sI https://example.com . Then reply with the HTTP status code only.")
        let tool = try #require(session.tools.first { $0.kind == .shell })
        #expect(tool.status == .succeeded, "got \(tool.status): \(tool.output)")
        await finish(session)
    }

    @Test func compactRunsTheRealCommand() async throws {
        let project = try makeProject()
        let session = try await makeSession(in: project, mode: .auto)
        try await run(session, "Reply with exactly: first")
        try await run(session, "/compact")
        #expect(session.notices.contains { $0.text.contains("compacted") }, "got \(session.notices.map(\.text))")
        await finish(session)
    }

    @Test func approvedCommandsRun() async throws {
        let project = try makeProject()
        let session = try await makeSession(in: project)
        var asked: [String] = []
        try await run(session, "Run this exact shell command: touch made.txt . Then reply with exactly: done") {
            asked.append($0.detail)
            return .allow()
        }
        #expect(asked.contains { $0.contains("touch made.txt") })
        #expect(asked.allSatisfy { !$0.contains("-lc") }, "the shell wrapper should be stripped")
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("made.txt").path))
        #expect(session.tools.contains { $0.kind == .shell && $0.status == .succeeded })
        #expect(session.turnEnds.last?.outcome == .completed)
        #expect(session.meta.conversationID != nil)
        #expect(session.context != nil)
        await finish(session)
    }

    @Test func filePatchesShowDiffs() async throws {
        let project = try makeProject()
        let session = try await makeSession(in: project)
        try await run(
            session,
            "Use the apply_patch tool (not the shell) to change 'first line' to 'second line' in notes.txt, and to add a new file extra.txt containing the word hello. Then reply with exactly: done")
        let contents = try String(contentsOf: project.appendingPathComponent("notes.txt"), encoding: .utf8)
        #expect(contents.contains("second line"))
        let edits = session.tools.filter { $0.kind == .edit }
        #expect(!edits.isEmpty, "got tools: \(session.tools.map(\.name))")
        let files = edits.flatMap(\.diff)
        let notes = try #require(files.first { $0.path == "notes.txt" }, "got paths: \(files.map(\.path))")
        #expect(notes.additions >= 1)
        #expect(notes.deletions >= 1)
        let added = try #require(files.first { $0.path == "extra.txt" })
        #expect(added.additions >= 1)
        await finish(session)
    }

    @Test func denyStopsAndChangesNothing() async throws {
        let project = try makeProject()
        let session = try await makeSession(in: project)
        try await run(session, "Run this exact shell command: touch denied.txt") { _ in .deny }
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("denied.txt").path))
        #expect(session.notices.isEmpty, "got: \(session.notices.map(\.text))")

        try await run(session, "Reply with exactly: still-here")
        #expect(session.assistantText.last?.contains("still-here") == true)
        await finish(session)
    }

    @Test func feedbackRedirects() async throws {
        let project = try makeProject()
        let session = try await makeSession(in: project)
        var denied = false
        try await run(session, "Run this exact shell command: touch nope.txt") { _ in
            if denied { return .allow() }
            denied = true
            return .denyWithFeedback("Do not run it. Reply with exactly: redirected")
        }
        // The guidance can arrive in the same turn or the next one.
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, session.assistantText.last?.contains("redirected") != true {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(session.assistantText.last?.contains("redirected") == true, "got: \(session.assistantText)")
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("nope.txt").path))
        await finish(session)
    }

    @Test func stopInterruptsAndTheSessionContinues() async throws {
        let project = try makeProject()
        let session = try await makeSession(in: project, mode: .auto)
        var stopped = false
        try await run(session, "Run the shell command: sleep 40 . Then reply with exactly: slept") { _ in .allow() } onRunning: {
            if !stopped, session.tools.contains(where: { $0.status == .running }) {
                stopped = true
                session.interrupt()
            }
        }
        #expect(stopped)
        #expect(session.turnEnds.last?.outcome == .interrupted)
        #expect(session.notices.isEmpty, "got: \(session.notices.map(\.text))")
        try await run(session, "Reply with exactly: resumed-ok")
        #expect(session.assistantText.last?.contains("resumed-ok") == true)
        await finish(session)
    }

    @Test func conversationsResumeInANewProcess() async throws {
        let project = try makeProject()
        let first = try await makeSession(in: project)
        try await run(first, "Remember the codeword: pineapple. Reply with exactly: ok")
        let id = try #require(first.meta.conversationID)
        await first.shutdown()

        let second = try await makeSession(in: project, conversationID: id)
        try await run(second, "What was the codeword? Reply with one word.")
        #expect(second.assistantText.last?.lowercased().contains("pineapple") == true, "got: \(second.assistantText)")
        await finish(second)
    }

    @Test func imagesAreUnderstood() async throws {
        let project = try makeProject()
        let imageURL = project.appendingPathComponent("red.png")
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try #require(bitmap.bitmapData)
        for row in 0..<64 {
            for column in 0..<64 {
                let offset = row * bitmap.bytesPerRow + column * 3
                (pixels[offset], pixels[offset + 1], pixels[offset + 2]) = (255, 0, 0)
            }
        }
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: imageURL)

        let session = try await makeSession(in: project)
        try await run(
            session, "What single colour fills this image? Reply with one word.",
            images: [ImageAttachment(path: imageURL.path, mediaType: "image/png")])
        #expect(session.assistantText.last?.lowercased().contains("red") == true, "got: \(session.assistantText)")
        await finish(session)
    }
}
