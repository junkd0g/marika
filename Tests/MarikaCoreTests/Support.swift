import Foundation
import Testing

@testable import MarikaCore

enum Fixture {
    static func url(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    }

    /// The frames of a recording of the real CLI.
    static func frames(_ name: String) throws -> [JSONValue] {
        let text = try String(contentsOf: url(name), encoding: .utf8)
        return try text.split(separator: "\n").map { try JSONValue(parsing: Data($0.utf8)) }
    }

    static func json(_ name: String) throws -> JSONValue {
        try JSONValue(parsing: Data(contentsOf: url(name)))
    }
}

/// An agent that does nothing, for driving the reducer directly.
actor IdleAgent: AgentSession {
    nonisolated let events: AsyncStream<AgentEvent>
    private let sink: AsyncStream<AgentEvent>.Continuation

    init() {
        (events, sink) = AsyncStream.makeStream(of: AgentEvent.self)
    }

    func send(_ input: UserInput) async throws {}
    func interrupt() async {}
    func hasActiveTurn() async -> Bool { false }
    func answer(requestID: String, decision: ApprovalDecision) async {}
    func update(settings: AgentSettings) async {}
    func shutdown() async { sink.finish() }
}

@MainActor
func replay(_ fixture: String, workingDirectory: String = "/tmp/project") throws -> SessionController {
    let meta = SessionMeta(projectID: UUID(), agent: .claude)
    let controller = SessionController(meta: meta) { _ in IdleAgent() }
    var translator = ClaudeTranslator(workingDirectory: workingDirectory)
    for frame in try Fixture.frames(fixture) {
        for event in translator.translate(frame) {
            controller.apply(event)
        }
    }
    controller.flushDeltas()
    return controller
}

extension SessionController {
    var tools: [ToolCall] { items.compactMap(\.tool) }

    var assistantText: [String] {
        items.compactMap { if case .assistant(let text) = $0.content { text } else { nil } }
    }

    var turnEnds: [TurnSummary] {
        items.compactMap { if case .turnEnd(let summary) = $0.content { summary } else { nil } }
    }

    var notices: [Notice] {
        items.compactMap { if case .notice(let notice) = $0.content { notice } else { nil } }
    }
}
