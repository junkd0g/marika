import Foundation

public struct NoteTextSelection: Equatable, Sendable {
    public let blockID: UUID
    public let sourceText: String
    public let range: NSRange
    public init(blockID: UUID, sourceText: String, range: NSRange) {
        self.blockID = blockID; self.sourceText = sourceText; self.range = range
    }
}

/// A frozen excerpt. Editing the source note later never rewrites a ticket's description.
public struct NoteTicketDraft: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let noteID: UUID
    public let spaceID: UUID
    public let noteTitle: String
    public var title: String
    public var body: String
    public var projectID: UUID?

    public init(note: SpaceNote, spaceID: UUID, blockID: UUID, selection: NoteTextSelection? = nil, projectID: UUID? = nil) throws {
        guard !note.archived, let block = note.blocks.first(where: { $0.id == blockID }) else {
            throw TicketWorkError("Restore this note and choose an existing block before creating a ticket.")
        }
        let excerpt: String
        if let selection {
            guard selection.blockID == blockID, selection.sourceText == block.text,
                  selection.range.location >= 0, selection.range.location <= block.text.utf16.count,
                  selection.range.length > 0, selection.range.length <= block.text.utf16.count - selection.range.location,
                  let range = Range(selection.range, in: block.text),
                  range.lowerBound.samePosition(in: block.text.unicodeScalars) != nil,
                  range.upperBound.samePosition(in: block.text.unicodeScalars) != nil else {
                throw TicketWorkError("The selected text changed. Select it again before creating a ticket.")
            }
            excerpt = String(block.text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else { excerpt = block.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !excerpt.isEmpty else { throw TicketWorkError("Choose some text before creating a ticket.") }
        id = UUID(); noteID = note.id; self.spaceID = spaceID; noteTitle = note.displayTitle
        title = String((excerpt.split(whereSeparator: \.isNewline).first.map(String.init) ?? excerpt).prefix(120))
        if block.kind == .code {
            let code = SpaceNote(title: note.displayTitle, blocks: [SpaceNoteBlock(kind: .code, text: excerpt)])
            body = String(code.markdown.dropFirst(("# " + code.displayTitle + "\n\n").count))
        } else { body = excerpt }
        self.projectID = projectID
    }
}

extension Workspace {
    @discardableResult public mutating func createTicket(from draft: NoteTicketDraft) throws -> SpaceTicket {
        guard let space = spaces.first(where: { $0.id == draft.spaceID }),
              let note = space.notes.first(where: { $0.id == draft.noteID }), !note.archived else {
            throw TicketWorkError("The source note moved or was archived. Restore it before creating a ticket.")
        }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw TicketWorkError("Give the ticket a title.") }
        if let projectID = draft.projectID, !projects(in: draft.spaceID).contains(where: { $0.id == projectID }) {
            throw TicketWorkError("Choose a project in the note's space.")
        }
        guard let ticket = createTicket(in: draft.spaceID) else { throw TicketWorkError("The source space is no longer available.") }
        updateTicket(ticket.id, in: draft.spaceID) {
            $0.title = title; $0.body = draft.body; $0.projectID = draft.projectID; $0.linkedNoteIDs = [draft.noteID]
        }
        return spaces.first { $0.id == draft.spaceID }!.tickets.first { $0.id == ticket.id }!
    }
}
