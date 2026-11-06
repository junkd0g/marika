import Foundation
import Testing

@testable import MarikaCore

/// Failure and timing behaviour, against a stand-in server that copies the real one's error text and
/// frame order. These started as reproductions from an audit against the real binary: each one
/// states the correct behaviour.
@MainActor
@Suite(.serialized)
struct CodexLifecycleTests {
    struct Fake {
        var executable: URL
        var log: URL
        var pids: URL
        var environment: [String: String]

        func sent() -> [JSONValue] {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { try? JSONValue(parsing: Data($0.utf8)) }
        }

        func methods() -> [String] { sent().compactMap { $0["method"]?.string } }

        func processIDs() -> [Int32] {
            let text = (try? String(contentsOf: pids, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { Int32($0) }
        }

        func alive() -> [Int32] { processIDs().filter { kill($0, 0) == 0 } }

        func reap() {
            for pid in alive() { kill(pid, SIGKILL) }
        }
    }

    private func install(_ mode: String) throws -> Fake {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("codex")
        try FileManager.default.copyItem(at: Fixture.url("fake-codex-lifecycle.py"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let log = directory.appendingPathComponent("sent.jsonl")
        let pids = directory.appendingPathComponent("pids")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        FileManager.default.createFile(atPath: pids.path, contents: nil)
        let environment = [
            "PATH": "/usr/bin:/bin", "FAKE_CODEX_LOG": log.path, "FAKE_PIDS": pids.path, "FAKE_MODE": mode,
            "HOME": NSHomeDirectory(),
        ]
        return Fake(executable: executable, log: log, pids: pids, environment: environment)
    }

    private func controller(
        _ fake: Fake, mode: ApprovalMode = .ask, conversationID: String? = nil, grace: Duration = .seconds(8),
        onAgent: ((CodexSession) -> Void)? = nil
    ) -> SessionController {
        let directory = fake.executable.deletingLastPathComponent()
        let environment = fake.environment
        let executable = fake.executable
        let meta = SessionMeta(projectID: UUID(), agent: .codex, conversationID: conversationID, mode: mode)
        return SessionController(meta: meta) { meta in
            let agent = CodexSession(
                launch: AgentLaunch(
                    executable: executable, environment: environment, workingDirectory: directory,
                    conversationID: meta.conversationID, settings: meta.settings),
                interruptGrace: grace)
            onAgent?(agent)
            return agent
        }
    }

    private func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    // MARK: Status

    @Test func statusGivesUpWhenTheServerNeverAnswers() async throws {
        let fake = try install("hang-init")
        defer { fake.reap() }
        let started = Date()
        let probe = await CodexCLI.probe(executable: fake.executable, environment: fake.environment)
        #expect(Date().timeIntervalSince(started) < 26)
        guard case .unavailable = probe.status.readiness else {
            Issue.record("a server that never answers isn't the same as signed out: \(probe.status.readiness)")
            return
        }
    }

    @Test func aBrokenCLIIsNotReportedAsSignedOut() async throws {
        let fake = try install("reject-init")
        defer { fake.reap() }
        let probe = await CodexCLI.probe(executable: fake.executable, environment: fake.environment)
        guard case .unavailable = probe.status.readiness else {
            Issue.record("got \(probe.status.readiness)")
            return
        }
    }

    // MARK: Stop

    @Test func stopDuringStartupStopsTheTurn() async throws {
        let fake = try install("thread-delay=0.8,hold-turn")
        defer { fake.reap() }
        let session = controller(fake)
        session.send(UserInput(text: "do something"))
        #expect(await waitUntil { !fake.processIDs().isEmpty })
        try await Task.sleep(for: .milliseconds(200))
        session.interrupt()
        #expect(await waitUntil { session.phase == .idle })
        #expect(!fake.methods().contains("turn/start") || fake.methods().contains("turn/interrupt"), "Stop was dropped")
        await session.shutdown()
    }

    @Test func stopRightAfterSendingStillStopsTheTurn() async throws {
        let fake = try install("hold-turn")
        defer { fake.reap() }
        let session = controller(fake, mode: .auto)
        session.send(UserInput(text: "start"))
        session.interrupt()
        #expect(await waitUntil { session.phase == .idle }, "phase \(session.phase), sent \(fake.methods())")
        await session.shutdown()
    }

    @Test func aNewTurnSurvivesTheStopWatchdogOfThePreviousOne() async throws {
        let fake = try install("hold-turn")
        defer { fake.reap() }
        let session = controller(fake, mode: .auto, grace: .milliseconds(600))
        session.send(UserInput(text: "first"))
        #expect(await waitUntil { !session.tools.isEmpty })
        session.interrupt()
        #expect(await waitUntil { session.phase == .idle })
        session.send(UserInput(text: "second"))
        #expect(await waitUntil { fake.methods().count { $0 == "turn/start" } == 2 })
        try await Task.sleep(for: .milliseconds(900))
        #expect(session.isBusy, "the watchdog for the first Stop killed the second turn")
        #expect(fake.alive().count == 1)
        await session.shutdown()
    }

    @Test func aWedgedTurnIsForcedToStop() async throws {
        let fake = try install("ignore-interrupt,hold-turn")
        defer { fake.reap() }
        let session = controller(fake, mode: .auto, grace: .milliseconds(400))
        session.send(UserInput(text: "start"))
        #expect(await waitUntil { !session.tools.isEmpty })
        session.interrupt()
        #expect(await waitUntil { session.phase == .idle }, "Stop must end the turn even if the server ignores it")
        #expect(session.turnEnds.last?.outcome == .interrupted)
        await session.shutdown()
    }

    // MARK: Shutdown races

    @Test func credentialChangesWaitForTheTurnAndReconnectOnTheNextMessage() async throws {
        let fake = try install("hold-turn")
        defer { fake.reap() }
        let session = controller(fake, mode: .auto)
        session.send(UserInput(text: "first"))
        #expect(await waitUntil { !session.tools.isEmpty })

        session.disconnectWhenIdle()
        #expect(session.isBusy)
        #expect(fake.alive().count == 1, "changing credentials must not cut off the current turn")
        #expect(!fake.methods().contains("turn/interrupt"))

        session.interrupt()
        #expect(await waitUntil { session.phase == .idle && fake.alive().isEmpty })
        #expect(session.turnEnds.last?.outcome == .interrupted)

        session.send(UserInput(text: "second"))
        #expect(await waitUntil { fake.methods().count { $0 == "turn/start" } == 2 })
        #expect(fake.processIDs().count == 2, "the next message needs a fresh agent with new credentials")
        #expect(session.isBusy)
        await session.shutdown()
    }

    @Test func deletingASessionDuringHandshakeStopsEverything() async throws {
        let fake = try install("init-delay=0.8,hold-turn")
        defer { fake.reap() }
        let session = controller(fake, mode: .auto)
        session.send(UserInput(text: "first message"))
        #expect(await waitUntil { !fake.processIDs().isEmpty })
        try await Task.sleep(for: .milliseconds(200))
        session.disconnect()
        try await Task.sleep(for: .seconds(2))
        #expect(!fake.methods().contains("turn/start"), "a turn started after the session was shut down")
        #expect(fake.alive().isEmpty, "the server outlived the session")
    }

    @Test func aQueuedSendDoesNotRelaunchAfterShutdown() async throws {
        let fake = try install("turnstart-delay=0.8,hold-turn")
        defer { fake.reap() }
        let session = controller(fake, mode: .auto)
        session.send(UserInput(text: "first"))
        session.send(UserInput(text: "second"))
        #expect(await waitUntil { fake.methods().contains("turn/start") })
        session.disconnect()
        try await Task.sleep(for: .seconds(2.5))
        #expect(fake.processIDs().count == 1, "a queued send launched a new server after shutdown")
        #expect(fake.alive().isEmpty)
    }

    // MARK: Failed handshakes

    @Test func aRejectedHandshakeDoesNotLeakTheServer() async throws {
        let fake = try install("reject-init")
        defer { fake.reap() }
        let session = controller(fake)
        session.send(UserInput(text: "one"))
        #expect(await waitUntil { !session.notices.isEmpty })
        try await Task.sleep(for: .seconds(0.5))
        #expect(await waitUntil(3) { fake.alive().isEmpty }, "a server that failed the handshake was left running")
        await session.shutdown()
    }

    @Test func aHungHandshakeCanBeStoppedAndShutDown() async throws {
        let fake = try install("hang-init")
        defer { fake.reap() }
        let session = controller(fake, grace: .milliseconds(300))
        session.send(UserInput(text: "one"))
        #expect(await waitUntil { !fake.processIDs().isEmpty })
        try await Task.sleep(for: .milliseconds(300))
        await session.shutdown()
        #expect(await waitUntil(6) { fake.alive().isEmpty }, "shutdown left the server running")
    }

    // MARK: Failed sends

    @Test func aRejectedMessageLeavesTheRunningTurnStoppable() async throws {
        let fake = try install("hold-turn,steer-reject=Input exceeds the maximum length of 1048576 characters.")
        defer { fake.reap() }
        let session = controller(fake, mode: .auto)
        session.send(UserInput(text: "start"))
        #expect(await waitUntil { !session.tools.isEmpty })
        session.send(UserInput(text: "more"))
        #expect(await waitUntil { !session.notices.isEmpty })
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.isBusy, "the turn is still running, so Stop must stay available")
        await session.shutdown()
    }

    @Test func rejectedFeedbackIsReported() async throws {
        let fake = try install("approval-then-hold,steer-reject=Input exceeds the maximum length of 1048576 characters.")
        defer { fake.reap() }
        let session = controller(fake)
        session.send(UserInput(text: "start"))
        #expect(await waitUntil { session.pendingApproval != nil })
        session.answer(try #require(session.pendingApproval), with: .denyWithFeedback("use the other approach"))
        #expect(await waitUntil { !session.notices.isEmpty }, "the guidance never arrived and nothing says so")
        await session.shutdown()
    }

    @Test func aMessageSentJustAfterStopIsNotLost() async throws {
        let fake = try install("hold-turn")
        defer { fake.reap() }
        let session = controller(fake, mode: .auto)
        session.send(UserInput(text: "start"))
        #expect(await waitUntil { !session.tools.isEmpty })
        session.interrupt()
        session.send(UserInput(text: "new instruction"))
        try await Task.sleep(for: .seconds(1))
        #expect(session.notices.isEmpty, "the message was shown as sent but rejected: \(session.notices.map(\.text))")
        #expect(fake.methods().count { $0 == "turn/start" } == 2)
        await session.shutdown()
    }

    // MARK: Crash

    @Test func aCrashSettlesRunningTools() async throws {
        let fake = try install("crash-in-command")
        defer { fake.reap() }
        let session = controller(fake, mode: .auto)
        session.send(UserInput(text: "start"))
        #expect(await waitUntil { !session.notices.isEmpty })
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.tools.allSatisfy { $0.status.isFinished }, "the crashed command still shows as running")
        #expect(session.notices.last?.text.contains("may still be running") == true)
        #expect(session.phase == .idle)
    }

    // MARK: Sub-agents

    @Test func aSubAgentFinishingDoesNotEndTheMainTurn() async throws {
        let fake = try install("child-run")
        defer { fake.reap() }
        let session = controller(fake, mode: .auto)
        session.send(UserInput(text: "use a sub-agent"))
        #expect(await waitUntil { session.tools.contains { $0.kind == .subagent && $0.status == .succeeded } })
        #expect(session.isBusy, "the sub-agent finishing made the running main turn read idle")
        #expect(session.turnEnds.isEmpty)
        #expect(await waitUntil(6) { !session.turnEnds.isEmpty })
        #expect(session.turnEnds.count == 1, "one turn produced \(session.turnEnds.count) turn ends")
        #expect(!session.assistantText.contains("sub-ok"), "the sub-agent's reply appeared as the assistant's own")

        let agent = try #require(session.tools.first { $0.kind == .subagent })
        #expect(agent.detail == "helper")
        #expect(agent.output == "sub-ok", "its answer belongs on its row")
        let nested = session.tools.filter { $0.parentID == agent.id }
        #expect(nested.map(\.kind) == [.shell], "what a sub-agent does must stay visible")
        await session.shutdown()
    }

    @Test func stopReachesTheMainTurnAndItsSubAgents() async throws {
        let fake = try install("child-run")
        defer { fake.reap() }
        let session = controller(fake, mode: .auto)
        session.send(UserInput(text: "use a sub-agent"))
        #expect(await waitUntil { session.tools.contains { $0.parentID != nil } })
        session.interrupt()
        #expect(await waitUntil { session.phase == .idle })
        let stopped = fake.sent().filter { $0["method"]?.string == "turn/interrupt" }.compactMap { $0["params"]?["turnId"]?.string }
        #expect(Set(stopped) == ["turn_main", "turn_child"], "got \(stopped)")
        #expect(session.notices.isEmpty, "\(session.notices.map(\.text))")
        await session.shutdown()
    }

    @Test func aMessageWhileASubAgentRunsGoesToTheMainThread() async throws {
        let fake = try install("child-run")
        defer { fake.reap() }
        let session = controller(fake, mode: .auto)
        session.send(UserInput(text: "use a sub-agent"))
        #expect(await waitUntil { session.tools.contains { $0.parentID != nil } })
        session.send(UserInput(text: "also do this"))
        #expect(await waitUntil { fake.methods().count { $0 == "turn/start" } == 2 })
        #expect(session.notices.isEmpty, "\(session.notices.map(\.text))")
        #expect(session.isBusy)
        await session.shutdown()
    }

    @Test func aSubAgentThatOutlivesTheTurnKeepsStopAvailable() async throws {
        let fake = try install("child-outlives")
        defer { fake.reap() }
        let session = controller(fake, mode: .auto)
        session.send(UserInput(text: "go"))
        #expect(await waitUntil { !session.turnEnds.isEmpty })
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.isBusy, "a sub-agent is still working, so there must still be a way to stop it")
        session.interrupt()
        #expect(await waitUntil { session.phase == .idle })
        await session.shutdown()
    }

    // MARK: Stale turn ids

    @Test func aFastTurnDoesNotLeaveAStaleTurnID() async throws {
        for _ in 0..<40 {
            let fake = try install("burst")
            defer { fake.reap() }
            var agent: CodexSession?
            let session = controller(fake, mode: .auto) { agent = $0 }
            session.send(UserInput(text: "go"))
            _ = await waitUntil { !session.turnEnds.isEmpty }
            try await Task.sleep(for: .milliseconds(10))
            let active = await agent?.hasActiveTurn() ?? false
            #expect(!active, "a finished turn left the session thinking one is running")
            await session.shutdown()
        }
    }

    // MARK: Resume

    @Test func aMissingConversationStartsFreshAndSaysSo() async throws {
        let fake = try install("resume-fail")
        defer { fake.reap() }
        let session = controller(fake, conversationID: "01a1ab59-0000-7000-8000-000000000000")
        session.send(UserInput(text: "one"))
        #expect(await waitUntil { !session.turnEnds.isEmpty })
        #expect(fake.methods().contains("thread/start"))
        #expect(session.notices.first?.text.contains("starting fresh") == true)
        #expect(session.meta.conversationID == "thr_main", "the new conversation should replace the dead one")
        await session.shutdown()
    }

    @Test func anArchivedConversationIsBroughtBack() async throws {
        let fake = try install("resume-archived")
        defer { fake.reap() }
        let session = controller(fake, conversationID: "thr_old")
        session.send(UserInput(text: "one"))
        #expect(await waitUntil { !session.turnEnds.isEmpty })
        #expect(fake.methods().contains("thread/unarchive"))
        #expect(!fake.methods().contains("thread/start"))
        #expect(session.notices.isEmpty)
        await session.shutdown()
    }

    @Test func aConversationIsOnlySavedOnceATurnExists() async throws {
        let fake = try install("steer-reject=x,turnstart-reject")
        defer { fake.reap() }
        let session = controller(fake)
        session.send(UserInput(text: "too long"))
        #expect(await waitUntil { !session.notices.isEmpty })
        #expect(session.meta.conversationID == nil, "a thread with no turn can't be resumed, so saving it would strand the session")
        await session.shutdown()
    }

    // MARK: Approvals outliving turns

    @Test func denyingOneOfTwoApprovalsClearsTheOther() async throws {
        let fake = try install("two-approvals")
        defer { fake.reap() }
        let session = controller(fake)
        session.send(UserInput(text: "two at once"))
        #expect(await waitUntil { session.approvals.count == 2 })
        session.answer(try #require(session.pendingApproval), with: .deny)
        #expect(await waitUntil { !session.turnEnds.isEmpty })
        try await Task.sleep(for: .milliseconds(200))
        #expect(session.pendingApproval == nil, "a dead request is still on screen after the turn ended")
        #expect(session.phase == .idle)
        await session.shutdown()
    }

    // MARK: Hung requests

    @Test func aHungTurnStartFailsInsteadOfSpinningForever() async throws {
        let fake = try install("turnstart-hang,hold-turn")
        defer { fake.reap() }
        let directory = fake.executable.deletingLastPathComponent()
        let environment = fake.environment
        let executable = fake.executable
        let meta = SessionMeta(projectID: UUID(), agent: .codex, mode: .auto)
        let session = SessionController(meta: meta) { meta in
            CodexSession(
                launch: AgentLaunch(
                    executable: executable, environment: environment, workingDirectory: directory, settings: meta.settings),
                requestTimeout: .milliseconds(500))
        }
        session.send(UserInput(text: "first"))
        #expect(await waitUntil(4) { !session.notices.isEmpty }, "still \(session.phase)")
        #expect(session.phase == .idle)

        // The wedged server is gone, so the next message gets a working one.
        session.send(UserInput(text: "second"))
        #expect(await waitUntil(5) { fake.processIDs().count == 2 })
        await session.shutdown()
    }

    @Test func aLaunchFailureLeavesNothingBehind() async throws {
        let meta = SessionMeta(projectID: UUID(), agent: .codex)
        let session = SessionController(meta: meta) { meta in
            CodexSession(
                launch: AgentLaunch(
                    executable: URL(fileURLWithPath: "/nonexistent/codex"), environment: [:],
                    workingDirectory: FileManager.default.temporaryDirectory, settings: meta.settings))
        }
        session.send(UserInput(text: "hello"))
        #expect(await waitUntil { !session.notices.isEmpty })
        try await Task.sleep(for: .milliseconds(200))
        #expect(session.phase == .idle)
        await session.shutdown()
    }

    @Test func closeFinishesEvenIfTheServerIgnoresTerm() async throws {
        let fake = try install("ignore-term")
        defer { fake.reap() }
        let session = controller(fake)
        session.send(UserInput(text: "one"))
        #expect(await waitUntil { !session.turnEnds.isEmpty })
        let started = Date()
        await session.shutdown()
        #expect(Date().timeIntervalSince(started) < 7, "quitting would wait on this")
        #expect(await waitUntil(2) { fake.alive().isEmpty })
    }
}
