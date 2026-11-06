import AppKit
import Foundation
import Testing

@testable import MarikaCore

/// Drives the real, signed-in `claude` CLI through the real engine.
/// Uses Haiku at low effort. Opt in with: MARIKA_LIVE=1 swift test --filter LiveClaudeTests
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MARIKA_LIVE"] != nil), .serialized)
struct LiveClaudeTests {
    private static var directory: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("marika-live-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSession(
        in directory: URL, mode: ApprovalMode = .ask, conversationID: String? = nil
    ) async throws -> SessionController {
        let shell = await ShellEnvironment.capture()
        let executable = try #require(ShellEnvironment.locate("claude", in: shell), "claude should be on the login PATH")
        let environment = ClaudeCLI.environment(base: shell, billing: .subscription, apiKey: nil)
        let meta = SessionMeta(
            projectID: UUID(), agent: .claude, conversationID: conversationID, model: "haiku", effort: "low", mode: mode)
        return SessionController(meta: meta) { meta in
            ClaudeSession(
                launch: AgentLaunch(
                    executable: executable, environment: environment, workingDirectory: directory,
                    conversationID: meta.conversationID, settings: meta.settings))
        }
    }

    /// Sends a prompt and answers every approval until the turn ends.
    private func run(
        _ session: SessionController, _ prompt: String, images: [ImageAttachment] = [],
        answer: (ApprovalRequest) -> ApprovalDecision? = { _ in .allow() },
        onRunning: (() -> Void)? = nil
    ) async throws {
        let turnsBefore = session.turnEnds.count
        session.send(UserInput(text: prompt, images: images))
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if let request = session.pendingApproval, let decision = answer(request) {
                session.answer(request, with: decision)
            }
            onRunning?()
            if session.turnEnds.count > turnsBefore, !session.isBusy { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("the turn did not finish; items: \(session.items.count), phase: \(session.phase)")
    }

    @Test func approvedEditsReachTheDisk() async throws {
        let directory = Self.directory
        let session = try await makeSession(in: directory)
        var asked: [String] = []
        try await run(session, "Use the Write tool to create notes.txt containing exactly: hi. Then say done.") {
            asked.append($0.title)
            return .allow()
        }
        #expect(asked.contains("Write this file?"))
        #expect(try String(contentsOf: directory.appendingPathComponent("notes.txt"), encoding: .utf8).contains("hi"))
        #expect(session.tools.first { $0.name == "Write" }?.status == .succeeded)
        #expect(session.tools.first { $0.name == "Write" }?.diff.first?.additions == 1)
        #expect(session.meta.conversationID != nil)
        #expect(session.turnEnds.last?.outcome == .completed)
        await session.shutdown()
    }

    @Test func denyStopsAndChangesNothing() async throws {
        let directory = Self.directory
        let session = try await makeSession(in: directory)
        try await run(session, "Use the Write tool to create denied.txt containing x.") { _ in .deny }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("denied.txt").path))
        #expect(session.tools.first { $0.name == "Write" }?.status == .denied)
        #expect(session.turnEnds.last?.outcome == .interrupted)
        #expect(session.notices.isEmpty)

        // The same process must still work after a denial.
        try await run(session, "Reply with exactly: still-here")
        #expect(session.assistantText.last?.contains("still-here") == true)
        await session.shutdown()
    }

    @Test func feedbackRedirectsWithoutStopping() async throws {
        let directory = Self.directory
        let session = try await makeSession(in: directory)
        var denied = false
        try await run(session, "Use the Write tool to create first.txt containing x.") { request in
            if !denied {
                denied = true
                return .denyWithFeedback("Do not create it. Reply with exactly: redirected")
            }
            return .allow()
        }
        #expect(session.turnEnds.last?.outcome == .completed)
        #expect(session.assistantText.last?.contains("redirected") == true)
        await session.shutdown()
    }

    @Test func stopInterruptsAndTheSessionContinues() async throws {
        let session = try await makeSession(in: Self.directory)
        var stopped = false
        try await run(session, "Count from 1 to 500, one number per line, no commentary.") { _ in .allow() } onRunning: {
            if !stopped, !session.assistantText.isEmpty {
                stopped = true
                session.interrupt()
            }
        }
        #expect(session.turnEnds.last?.outcome == .interrupted)
        #expect(session.notices.isEmpty, "a user stop must not read as an error")
        try await run(session, "Reply with exactly: resumed-ok")
        #expect(session.assistantText.last?.contains("resumed-ok") == true)
        await session.shutdown()
    }

    @Test func conversationsResumeInANewProcess() async throws {
        let directory = Self.directory
        let first = try await makeSession(in: directory)
        try await run(first, "Remember the codeword: pineapple. Reply with exactly: ok")
        let id = try #require(first.meta.conversationID)
        await first.shutdown()

        let second = try await makeSession(in: directory, conversationID: id)
        try await run(second, "What was the codeword? Reply with one word.")
        #expect(second.assistantText.last?.lowercased().contains("pineapple") == true)
        await second.shutdown()
    }

    @Test func questionsAreAnswered() async throws {
        let session = try await makeSession(in: Self.directory)
        try await run(
            session,
            "Use the AskUserQuestion tool to ask whether I prefer tabs or spaces, with those two options. Then tell me what I picked."
        ) { request in
            guard case .questions(let questions) = request.kind else { return .allow() }
            return .answers(Dictionary(uniqueKeysWithValues: questions.map { ($0.id, ["Spaces"]) }))
        }
        #expect(session.assistantText.last?.lowercased().contains("spaces") == true)
        await session.shutdown()
    }

    @Test func approvingAPlanCanSwitchToAcceptEdits() async throws {
        let directory = Self.directory
        let session = try await makeSession(in: directory, mode: .plan)
        var sawPlan = false
        var askedAfterPlan = false
        try await run(session, "Plan to create plan.txt containing yes. Keep it to one step. Then exit plan mode.") { request in
            if case .plan = request.kind {
                sawPlan = true
                return .approvePlan(then: .acceptEdits)
            }
            if sawPlan, request.toolKind == .write { askedAfterPlan = true }
            return .allow()
        }
        #expect(sawPlan)
        #expect(!askedAfterPlan, "accept-edits should cover the write")
        #expect(session.meta.mode == .acceptEdits)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("plan.txt").path))
        await session.shutdown()
    }

    @Test func modeAndModelChangeBetweenTurns() async throws {
        let directory = Self.directory
        let session = try await makeSession(in: directory)
        try await run(session, "Reply with exactly: one")

        var settings = session.meta.settings
        settings.mode = .acceptEdits
        settings.model = "sonnet"
        session.update(settings: settings)
        var asked = false
        try await run(session, "Use Write to create auto.txt containing y. Then reply: two") {
            if $0.toolKind == .write { asked = true }
            return .allow()
        }
        #expect(!asked)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("auto.txt").path))
        await session.shutdown()
    }

    @Test func bypassAndEffortChangesRelaunchSafely() async throws {
        let directory = Self.directory
        let session = try await makeSession(in: directory)
        try await run(session, "Reply with exactly: one")

        var settings = session.meta.settings
        settings.mode = .bypass
        settings.effort = "medium"
        session.update(settings: settings)
        var asked = false
        try await run(session, "Use Bash to run: touch bypassed.txt. Then reply: two") { _ in
            asked = true
            return .allow()
        }
        #expect(!asked, "bypass should not ask")
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("bypassed.txt").path))
        #expect(session.meta.mode == .bypass)
        await session.shutdown()
    }

    @Test func imagesAreUnderstood() async throws {
        let directory = Self.directory
        let imageURL = directory.appendingPathComponent("red.png")
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

        let session = try await makeSession(in: directory)
        try await run(
            session, "What single colour fills this image? Reply with one word.",
            images: [ImageAttachment(path: imageURL.path, mediaType: "image/png")])
        #expect(session.assistantText.last?.lowercased().contains("red") == true, "got: \(session.assistantText) notices: \(session.notices.map(\.text))")
        await session.shutdown()
    }

    @Test func statusAndCapabilitiesComeFromTheCLI() async throws {
        let shell = await ShellEnvironment.capture()
        let executable = try #require(ShellEnvironment.locate("claude", in: shell))
        let environment = ClaudeCLI.environment(base: shell, billing: .subscription, apiKey: nil)
        let status = await ClaudeCLI.status(executable: executable, environment: environment)
        #expect(status.readiness == .ready)
        #expect(status.plan != nil)
        let capabilities = await ClaudeCLI.capabilities(executable: executable, environment: environment)
        #expect(capabilities?.models.isEmpty == false)
        #expect(capabilities?.commands.isEmpty == false)
    }
}
