import Foundation

public struct DesignImportFile: Codable, Hashable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let framework: String
    public let bytes: Int
    public let priority: Int
    public var digest: String?
    public var lines: Int?
    public init(path: String, framework: String, bytes: Int, priority: Int = 0, digest: String? = nil, lines: Int? = nil) {
        self.path = path; self.framework = framework; self.bytes = bytes; self.priority = priority
        self.digest = digest; self.lines = lines
    }
}

public struct DesignImportRun: Codable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case preparing, running, ready, applied, cancelled, failed }
    public let id: UUID
    public let sessionID: UUID
    public let projectPath: String
    public let agent: AgentKind
    public let date: Date
    public var status: Status = .preparing
    public var files: [DesignImportFile] = []
    public var proposal: DesignImportProposal?
    public var error: String?
    public var isActive: Bool { status == .preparing || status == .running }
    public init(id: UUID = UUID(), sessionID: UUID = UUID(), projectPath: String, agent: AgentKind) {
        self.id = id; self.sessionID = sessionID; self.projectPath = projectPath; self.agent = agent; date = Date()
    }
}

public struct DesignImportProposal: Codable, Hashable, Sendable {
    public let summary: String
    public let notes: [String]
    public let document: DesignDocument

    public static func parse(_ response: String, files: [DesignImportFile]) throws -> Self {
        guard response.utf8.count <= 1_000_000 else { throw DesignToolError("The generated design is too large. Import fewer files.") }
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), let opening = text.firstIndex(of: "\n"), text.hasSuffix("```") {
            text = String(text[text.index(after: opening)..<text.index(text.endIndex, offsetBy: -3)])
        }
        let value: JSONValue
        do { value = try JSONValue(parsing: Data(text.utf8)) }
        catch { throw DesignToolError("The agent returned an explanation instead of a design draft. Try again with a specific screen or fewer files.") }
        guard let summary = value["summary"]?.string, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              summary.count <= 2_000, let design = value["design"], design.object != nil else {
            throw DesignToolError("The agent did not return a complete design draft. Try again with fewer files or a more specific screen.")
        }
        let rawNotes = value["notes"]?.array ?? []
        guard rawNotes.count <= 12, rawNotes.allSatisfy({ $0.string != nil && ($0.string?.count ?? 0) <= 500 }) else {
            throw DesignToolError("The draft contains invalid design notes.")
        }
        let empty = DesignDocument()
        var document = try DesignTools.publish(["baseRevision": .string(DesignTools.revision(of: empty)),
            "design": .string(String(decoding: try design.serialized(), as: UTF8.self))], replacing: empty)
        guard !document.nodes.isEmpty else { throw DesignToolError("The agent returned an empty design. Choose UI source files and try again.") }
        guard Set(files.map(\.path)).count == files.count else { throw DesignToolError("The source inventory contains duplicate files.") }
        let sources = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        var references = 0
        for index in document.nodes.indices {
            document.nodes[index].isLocked = false; document.nodes[index].isHidden = false
            for link in document.nodes[index].links ?? [] {
                guard link.kind == .file, let file = sources[link.target], let line = link.line,
                      line >= 1, line <= (file.lines ?? 0) else {
                    throw DesignToolError("The draft cites a file or line outside the selected source: " + link.target)
                }
                references += 1
            }
        }
        guard references > 0 else { throw DesignToolError("The draft has no source links. Generate it again so the design can be traced to your code.") }
        return Self(summary: summary, notes: rawNotes.compactMap(\.string), document: document)
    }

    /// Adds a separately movable section, preserving every existing layer and connection.
    public func appending(to current: DesignDocument) throws -> (document: DesignDocument, selection: UUID) {
        guard current.nodes.count + document.nodes.count + 1 <= 500,
              (current.connections?.count ?? 0) + (document.connections?.count ?? 0) <= 1_000,
              let bounds = document.bounds(of: Set(document.nodes.map(\.id))) else {
            throw DesignToolError("There is not enough space in this canvas. Import fewer components or use a new project canvas.")
        }
        let oldBounds = current.bounds(of: Set(current.nodes.map(\.id)))
        let dx = (oldBounds.map { $0.maxX + 160 } ?? 40) - bounds.minX
        let dy = (oldBounds?.minY ?? 40) - bounds.minY
        let frame = bounds.offsetBy(dx: dx, dy: dy).insetBy(dx: -40, dy: -60)
        guard max(abs(frame.minX), abs(frame.maxX), abs(frame.minY), abs(frame.maxY)) <= 100_000 else {
            throw DesignToolError("Move the existing design closer to the canvas origin before importing.")
        }
        var result = current
        let wrapper = result.add(.frame, in: frame)
        result.update([wrapper]) { $0.name = document.title ?? "Imported design"; $0.text = ""; $0.description = summary }
        let ids = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, UUID()) })
        result.nodes += document.nodes.map { node in
            var copy = node; copy.id = ids[node.id]!; copy.x += dx; copy.y += dy
            copy.links = copy.links?.map { var link = $0; link.id = UUID(); return link }
            return copy
        }
        let connections = (document.connections ?? []).map { edge in
            var copy = edge; copy.id = UUID(); copy.from = ids[edge.from]!; copy.to = ids[edge.to]!; return copy
        }
        if !connections.isEmpty { result.connections = (result.connections ?? []) + connections }
        if result.title == nil { result.title = document.title }
        return (result, wrapper)
    }
}
