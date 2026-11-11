import Foundation

public struct DesignSourceLink: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case file, symbol, endpoint, documentation }
    public var id: UUID
    public var kind: Kind
    public var target: String
    public var line: Int?
    public var symbol: String?
    public var symbolIdentity: DesignSymbolIdentity?
    public init(id: UUID = UUID(), kind: Kind, target: String, line: Int? = nil, symbol: String? = nil, symbolIdentity: DesignSymbolIdentity? = nil) {
        self.id = id; self.kind = kind; self.target = target; self.line = line; self.symbol = symbol; self.symbolIdentity = symbolIdentity
    }
    private enum CodingKeys: String, CodingKey { case id, kind, target, line, symbol, symbolIdentity }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind); target = try c.decode(String.self, forKey: .target)
        line = try c.decodeIfPresent(Int.self, forKey: .line); symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        symbolIdentity = try c.decodeIfPresent(DesignSymbolIdentity.self, forKey: .symbolIdentity)
    }
    public var isValid: Bool {
        guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, target.count <= 2_048,
              (symbol?.count ?? 0) <= 2_000, symbolIdentity?.isValid != false,
              line.map({ (1...10_000_000).contains($0) }) ?? true else { return false }
        switch kind {
        case .file, .symbol:
            return !target.hasPrefix("/") && !target.split(separator: "/").contains("..") && !target.contains("\0")
        case .endpoint: return target.count <= 500
        case .documentation:
            guard let url = URL(string: target) else { return false }
            return ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil
        }
    }
    public var displayName: String {
        (symbolIdentity?.name ?? (symbol?.isEmpty == false ? symbol! : target)) + (kind == .symbol ? "" : line.map { ":\($0)" } ?? "")
    }
}

public struct DesignVersion: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public let date: Date
    public let document: DesignDocument
    public init(name: String, document: DesignDocument, date: Date = Date()) {
        id = UUID(); self.name = String(name.prefix(120)); self.document = document; self.date = date
    }
}

public struct DesignDifference: Sendable {
    public let added: Set<UUID>
    public let removed: Set<UUID>
    public let changed: Set<UUID>
    public let connectionsChanged: Int
    public let titleChanged: Bool
    public init(before: DesignDocument, after: DesignDocument) {
        let old = Dictionary(uniqueKeysWithValues: before.nodes.map { ($0.id, $0) })
        let new = Dictionary(uniqueKeysWithValues: after.nodes.map { ($0.id, $0) })
        added = Set(new.keys).subtracting(old.keys); removed = Set(old.keys).subtracting(new.keys)
        changed = Set(new.keys).intersection(old.keys).filter { old[$0] != new[$0] }
        let oldEdges = Dictionary(uniqueKeysWithValues: (before.connections ?? []).map { ($0.id, $0) })
        let newEdges = Dictionary(uniqueKeysWithValues: (after.connections ?? []).map { ($0.id, $0) })
        connectionsChanged = Set(oldEdges.keys).union(newEdges.keys).filter { oldEdges[$0] != newEdges[$0] }.count
        titleChanged = before.title != after.title
    }
    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty && connectionsChanged == 0 && !titleChanged }
}

public struct DesignTicketSource: Codable, Hashable, Sendable {
    public var projectID: UUID
    public var elementIDs: [UUID]
    public init(projectID: UUID, elementIDs: Set<UUID>) {
        self.projectID = projectID; self.elementIDs = elementIDs.sorted { $0.uuidString < $1.uuidString }
    }
}

public struct DesignTicketDraft: Identifiable, Sendable {
    public let id = UUID()
    public let source: DesignTicketSource
    public var title: String
    public var requirements: String
    public var acceptance: String
    public init(projectID: UUID, document: DesignDocument, selection: Set<UUID>) throws {
        let nodes = document.nodes.filter { selection.contains($0.id) && !$0.isHidden }
        guard !nodes.isEmpty else { throw TicketWorkError("Select at least one design element first.") }
        source = DesignTicketSource(projectID: projectID, elementIDs: Set(nodes.map(\.id)))
        title = String(("Implement " + nodes.map(\.name).joined(separator: ", ")).prefix(120))
        requirements = nodes.map { "## " + $0.name + "\n" + ($0.description ?? "Define this component's behavior before implementation.") }.joined(separator: "\n\n")
        acceptance = "Implement the described responsibilities and interfaces.\nCover success and failure paths with automated tests.\nVerify the selected connections work end to end.\nDocument configuration and how to run the changes."
    }
    public var body: String {
        requirements.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n## Acceptance criteria\n"
            + acceptance.split(whereSeparator: \.isNewline).map { "- [ ] " + $0 }.joined(separator: "\n")
    }
}

extension Workspace {
    @discardableResult public mutating func createTicket(from draft: DesignTicketDraft) throws -> SpaceTicket {
        guard let project = projects.first(where: { $0.id == draft.source.projectID }), let spaceID = project.spaceID,
              let document = project.design, !draft.source.elementIDs.isEmpty,
              Set(draft.source.elementIDs).isSubset(of: Set(document.nodes.map(\.id))) else {
            throw TicketWorkError("The project or selected design elements changed. Create the draft again.")
        }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !draft.acceptance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              draft.body.count <= 24_000 else { throw TicketWorkError("Add a title and acceptance criteria, and keep the ticket below 24,000 characters.") }
        guard let ticket = createTicket(in: spaceID) else { throw TicketWorkError("The project's space is unavailable.") }
        updateTicket(ticket.id, in: spaceID) {
            $0.title = title; $0.body = draft.body; $0.projectID = project.id; $0.kind = .feature; $0.designSource = draft.source
        }
        return spaces.first { $0.id == spaceID }!.tickets.first { $0.id == ticket.id }!
    }
}
