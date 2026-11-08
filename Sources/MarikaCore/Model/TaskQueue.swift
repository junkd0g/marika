import Foundation

public struct ResearchTaskReference: Codable, Hashable, Sendable {
    public var runID: UUID
    public var findingID: String
    public init(runID: UUID, findingID: String) { self.runID = runID; self.findingID = findingID }
}

public struct QueuedAgentTask: Codable, Hashable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case queued, launching, launched, failed, cancelled }
    public var id = UUID()
    public var date = Date()
    public var title: String
    public var prompt: String
    public var agent: AgentKind
    public var settings: AgentSettings
    public var isolated: Bool
    public var parentSessionID: UUID?
    public var research: ResearchTaskReference?
    public var state: State = .queued
    public var sessionID: UUID?
    public var error: String?

    public init(title: String, prompt: String, agent: AgentKind, settings: AgentSettings, isolated: Bool = true,
                parentSessionID: UUID? = nil, research: ResearchTaskReference? = nil) throws {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.count <= 32_000, title.count <= 80 else {
            throw AgentError.launchFailed("Describe a task under 32,000 characters and a name under 80 characters.")
        }
        self.title = title.isEmpty ? AgentTaskName.suggested(from: prompt) : title
        self.prompt = prompt; self.agent = agent; self.settings = settings; self.isolated = isolated
        self.parentSessionID = parentSessionID; self.research = research
    }
}

public struct AgentTaskQueue: Codable, Hashable, Sendable {
    public var items: [QueuedAgentTask] = []
    public var isPaused = false
    public init() {}
    public var pendingCount: Int { items.count { $0.state == .queued || $0.state == .launching } }
    public var next: QueuedAgentTask? { isPaused ? nil : items.first { $0.state == .queued } }

    public mutating func append(_ item: QueuedAgentTask) throws {
        guard items.count(where: { [.queued, .launching, .failed].contains($0.state) }) < 50 else {
            throw AgentError.launchFailed("This queue already has 50 pending tasks. Finish or cancel some before adding more.")
        }
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.append(item)
        let history = Set(items.filter { $0.state == .launched || $0.state == .cancelled }.suffix(30).map(\.id))
        items.removeAll { ($0.state == .launched || $0.state == .cancelled) && !history.contains($0.id) }
    }

    public mutating func move(_ id: UUID, offset: Int) {
        let positions = items.indices.filter { items[$0].state == .queued }
        guard let from = positions.firstIndex(where: { items[$0].id == id }), positions.indices.contains(from + offset) else { return }
        items.swapAt(positions[from], positions[from + offset])
    }

    public mutating func cancel(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id && ($0.state == .queued || $0.state == .failed) }) else { return }
        items[index].state = .cancelled; items[index].error = nil
    }

    public mutating func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id && $0.state == .failed }) else { return }
        items[index].state = .queued; items[index].error = nil
    }

    /// Never repeat a launch whose result was uncertain when the app stopped.
    public mutating func recover(sessions: [SessionMeta]) {
        for index in items.indices where items[index].state == .launching {
            if let session = sessions.first(where: { $0.agentTask?.queueID == items[index].id }) {
                items[index].sessionID = session.id; items[index].state = .launched
            } else {
                items[index].state = .failed
                items[index].error = "Launch was interrupted. Check existing agents before retrying."
            }
        }
        if items.contains(where: { $0.state == .queued || $0.state == .failed }) { isPaused = true }
    }
}
