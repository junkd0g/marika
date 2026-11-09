import Foundation
import Testing
@testable import MarikaCore

@MainActor struct SessionCheckpointTests {
    private func controller() -> SessionController {
        SessionController(meta: SessionMeta(projectID: UUID(), agent: .codex)) { _ in IdleAgent() }
    }

    @Test func continuousOutputIsSavedAndRecoverableBeforeTheTurnFinishes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("marika-stream-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root), session = controller()
        var writes: [Task<Void, Error>] = []
        session.onChange = { current in
            let items = current.items
            writes.append(Task { try await store.saveTranscript(items, for: current.id) })
        }
        session.apply(.phaseChanged(.running))
        // Never leave enough silence for a debounce, and don't send a finished event.
        for _ in 0..<50 {
            session.apply(.textDelta(id: "answer", delta: "stream ", parentToolID: nil))
            session.apply(.thinkingDelta(id: "thinking", delta: "reason ", parentToolID: nil))
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(session.isBusy)
        #expect(writes.count >= 2 && writes.count < 25, "Streaming should checkpoint periodically, not once per token")
        for write in writes { try await write.value }
        let restored = SessionController(meta: session.meta, items: try await store.loadTranscript(session.id)) { _ in IdleAgent() }
        #expect(restored.assistantText.first?.hasPrefix("stream stream ") == true)
        #expect(restored.items.contains { if case .thinking(let text, _) = $0.content { return text.hasPrefix("reason reason ") }; return false })
        #expect(restored.turnEnds.isEmpty)
        await session.shutdown()
        for write in writes { try await write.value }
    }

    @Test func unfinishedToolsAndNoticesReachTheCheckpoint() async throws {
        let session = controller()
        var snapshots: [[TranscriptItem]] = []
        session.onChange = { snapshots.append($0.items) }
        session.apply(.tool(ToolCall(id: "tool", name: "Bash", kind: .shell, title: "Build", detail: "build")))
        session.apply(.toolOutput(id: "tool", delta: "still building"))
        session.apply(.notice(Notice(level: .warning, text: "retrying", key: "retry")))
        let deadline = ContinuousClock.now + .seconds(3)
        while snapshots.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let saved = try #require(snapshots.first)
        #expect(saved.compactMap(\.tool).first?.output == "still building")
        #expect(saved.contains { if case .notice(let notice) = $0.content { return notice.text == "retrying" }; return false })
    }

    @Test func turnCompletionSavesFinalTextImmediatelyWithoutADuplicateCheckpoint() async throws {
        let session = controller()
        var snapshots: [[TranscriptItem]] = []
        session.onChange = { snapshots.append($0.items) }
        session.apply(.textDelta(id: "answer", delta: "final text", parentToolID: nil))
        session.apply(.turnFinished(TurnSummary(outcome: .completed)))
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.contains { if case .assistant(let text) = $0.content { return text == "final text" }; return false } == true)
        try await Task.sleep(for: .milliseconds(1200))
        #expect(snapshots.count == 1)
    }

    @Test func shutdownFlushesTextThatHasNotReachedItsDisplayOrSaveDeadline() async {
        let session = controller()
        var savedText: [String] = []
        session.onChange = { savedText = $0.assistantText }
        session.apply(.textDelta(id: "answer", delta: "last tokens", parentToolID: nil))
        await session.shutdown()
        #expect(savedText == ["last tokens"])
    }
}
