import Foundation

public enum SpaceSection: String, Codable, CaseIterable, Sendable {
    case projects = "Projects", notes = "Notes", tickets = "Tickets", attention = "Needs attention"
}

public struct SpaceNoteBlock: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case text = "Text", heading = "Heading", subheading = "Subheading", bullet = "Bullet list"
        case checklist = "Checklist", quote = "Quote", code = "Code"
    }
    public var id: UUID
    public var kind: Kind
    public var text: String
    public var checked: Bool
    public init(id: UUID = UUID(), kind: Kind = .text, text: String = "", checked: Bool = false) {
        self.id = id; self.kind = kind; self.text = text; self.checked = checked
    }
}

public struct SpaceNote: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var blocks: [SpaceNoteBlock]
    public var pinned: Bool
    public var archived: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var displayTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled note" : title }
    public var searchableText: String { ([title] + blocks.map(\.text)).joined(separator: " ") }
    public init(id: UUID = UUID(), title: String = "", blocks: [SpaceNoteBlock] = [SpaceNoteBlock()], date: Date = Date()) {
        self.id = id; self.title = title; self.blocks = blocks; pinned = false; archived = false
        createdAt = date; updatedAt = date
    }
    public var markdown: String {
        "# " + displayTitle + "\n\n" + blocks.map { block in
            switch block.kind {
            case .text: return block.text
            case .heading: return "## " + block.text
            case .subheading: return "### " + block.text
            case .bullet: return "- " + block.text.replacingOccurrences(of: "\n", with: "\n  ")
            case .checklist: return "- [\(block.checked ? "x" : " ")] " + block.text.replacingOccurrences(of: "\n", with: "\n  ")
            case .quote: return "> " + block.text.replacingOccurrences(of: "\n", with: "\n> ")
            case .code:
                // Use a longer fence when a code sample itself contains Markdown fences.
                let longestRun = block.text.split(omittingEmptySubsequences: true, whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
                let fence = String(repeating: "`", count: max(3, longestRun + 1))
                return fence + "\n" + block.text + "\n" + fence
            }
        }.joined(separator: "\n\n")
    }
}

public struct SpaceTicket: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, CaseIterable, Sendable {
        case backlog = "Backlog", todo = "To Do", inProgress = "In Progress", done = "Done"
    }
    public enum Priority: String, Codable, CaseIterable, Sendable {
        case low = "Low", medium = "Medium", high = "High", urgent = "Urgent"
    }
    public enum Kind: String, Codable, CaseIterable, Sendable { case task = "Task", bug = "Bug", feature = "Feature" }
    public var id: UUID
    public var key: String
    public var title: String
    public var body: String
    public var status: Status
    public var priority: Priority
    public var kind: Kind
    public var assignee: String
    public var projectID: UUID?
    public var archived: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var linkedNoteIDs: [UUID]?
    public var work: [TicketWork]?
    public var designSource: DesignTicketSource?
    public var displayTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled ticket" : title }
    public init(id: UUID = UUID(), key: String, title: String = "", status: Status = .todo, date: Date = Date()) {
        self.id = id; self.key = key; self.title = title; self.status = status
        body = ""; priority = .medium; kind = .task; assignee = ""; projectID = nil; archived = false
        createdAt = date; updatedAt = date
    }
    public var searchableText: String { [key, title, body, assignee, kind.rawValue].joined(separator: " ") }
}

extension Workspace {
    @discardableResult public mutating func createNote(in spaceID: UUID) -> SpaceNote? {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return nil }
        let note = SpaceNote(); spaces[index].notes.append(note); return note
    }
    @discardableResult public mutating func updateNote(_ id: UUID, in spaceID: UUID, change: (inout SpaceNote) -> Void) -> Bool {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }),
              let item = spaces[index].notes.firstIndex(where: { $0.id == id }) else { return false }
        change(&spaces[index].notes[item]); spaces[index].notes[item].updatedAt = Date()
        if spaces[index].notes[item].blocks.isEmpty { spaces[index].notes[item].blocks = [SpaceNoteBlock()] }
        return true
    }
    @discardableResult public mutating func createTicket(in spaceID: UUID, status: SpaceTicket.Status = .todo) -> SpaceTicket? {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return nil }
        let existing = Set(spaces.flatMap(\.tickets).map(\.key))
        var number = max(1, spaces[index].nextTicketNumber)
        while existing.contains("\(spaces[index].ticketPrefix)-\(number)") { number += 1 }
        let ticket = SpaceTicket(key: "\(spaces[index].ticketPrefix)-\(number)", status: status)
        spaces[index].nextTicketNumber = number + 1
        spaces[index].tickets.append(ticket)
        return ticket
    }
    @discardableResult public mutating func updateTicket(_ id: UUID, in spaceID: UUID, change: (inout SpaceTicket) -> Void) -> Bool {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }),
              let item = spaces[index].tickets.firstIndex(where: { $0.id == id }) else { return false }
        let key = spaces[index].tickets[item].key
        change(&spaces[index].tickets[item]); spaces[index].tickets[item].updatedAt = Date()
        spaces[index].tickets[item].key = key
        if let projectID = spaces[index].tickets[item].projectID, !projects(in: spaceID).contains(where: { $0.id == projectID }) {
            spaces[index].tickets[item].projectID = nil
        }
        let notes = Set(spaces[index].notes.map(\.id))
        spaces[index].tickets[item].linkedNoteIDs = spaces[index].tickets[item].linkedNoteIDs.map { Array(Set($0)).filter(notes.contains).sorted { $0.uuidString < $1.uuidString } }
        return true
    }
    mutating func normalizeSpaceContent() {
        var prefixes = Set<String>()
        for index in spaces.indices {
            let base = spaces[index].ticketPrefix
            var prefix = base, suffix = 2
            while !prefixes.insert(prefix).inserted { prefix = base + String(suffix); suffix += 1 }
            spaces[index].ticketPrefix = prefix
            let projectIDs = Set(projects(in: spaces[index].id).map(\.id))
            let noteIDs = Set(spaces[index].notes.map(\.id))
            for item in spaces[index].tickets.indices {
                if let id = spaces[index].tickets[item].projectID, !projectIDs.contains(id) { spaces[index].tickets[item].projectID = nil }
                spaces[index].tickets[item].linkedNoteIDs = spaces[index].tickets[item].linkedNoteIDs.map { Array(Set($0)).filter(noteIDs.contains).sorted { $0.uuidString < $1.uuidString } }
            }
        }
    }
}
