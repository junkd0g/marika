import Foundation
import Testing
@testable import MarikaCore

struct NoteTicketTests {
    private func fixture() -> (Workspace, SpaceNote, SpaceNoteBlock, Project) {
        let block = SpaceNoteBlock(kind: .checklist, text: "Improve keyboard navigation\nKeep the current shortcuts", checked: true)
        let note = SpaceNote(title: "Product plan", blocks: [block])
        var space = ProjectSpace.personal; space.notes = [note]
        let project = Project(path: "/product")
        return (Workspace(projects: [project], spaces: [space]), note, block, project)
    }

    @Test func creatingFromAChecklistKeepsTheNoteAndCompletionState() throws {
        var (workspace, note, block, project) = fixture()
        let draft = try NoteTicketDraft(note: note, spaceID: ProjectSpace.personalID, blockID: block.id, projectID: project.id)
        let ticket = try workspace.createTicket(from: draft)
        #expect(ticket.title == "Improve keyboard navigation" && ticket.body == block.text)
        #expect(ticket.linkedNoteIDs == [note.id] && ticket.projectID == project.id && ticket.status == .todo)
        #expect(workspace.spaces[0].notes[0] == note && workspace.spaces[0].notes[0].blocks[0].checked)
    }

    @Test func selectionUsesUTF16RangesWithoutIncludingOtherText() throws {
        let block = SpaceNoteBlock(text: "A 👩🏽‍💻 idea: support Ελληνικά and café. Keep the rest in the note.")
        let note = SpaceNote(title: "Ideas", blocks: [block])
        let excerpt = "support Ελληνικά and café"
        let selection = NoteTextSelection(blockID: block.id, sourceText: block.text, range: (block.text as NSString).range(of: excerpt))
        let draft = try NoteTicketDraft(note: note, spaceID: ProjectSpace.personalID, blockID: block.id, selection: selection)
        #expect(draft.body == excerpt && draft.title == excerpt)
    }

    @Test func staleMissingEmptyAndBrokenSelectionsAreRejected() throws {
        let block = SpaceNoteBlock(text: "🚀 Launch the project")
        let note = SpaceNote(title: "Plan", blocks: [block])
        for selection in [
            NoteTextSelection(blockID: block.id, sourceText: "Old text", range: NSRange(location: 0, length: 3)),
            NoteTextSelection(blockID: UUID(), sourceText: block.text, range: NSRange(location: 0, length: 2)),
            NoteTextSelection(blockID: block.id, sourceText: block.text, range: NSRange(location: 0, length: 0)),
            NoteTextSelection(blockID: block.id, sourceText: block.text, range: NSRange(location: 1, length: 1)),
            NoteTextSelection(blockID: block.id, sourceText: block.text, range: NSRange(location: 200, length: 2)),
        ] {
            #expect(throws: TicketWorkError.self) { try NoteTicketDraft(note: note, spaceID: ProjectSpace.personalID, blockID: block.id, selection: selection) }
        }
        #expect(throws: TicketWorkError.self) { try NoteTicketDraft(note: note, spaceID: ProjectSpace.personalID, blockID: UUID()) }
        let empty = SpaceNote(title: "Empty")
        #expect(throws: TicketWorkError.self) { try NoteTicketDraft(note: empty, spaceID: ProjectSpace.personalID, blockID: empty.blocks[0].id) }
    }

    @Test func invalidProjectsAndTitlesLeaveNoPartialTicketOrConsumedKey() throws {
        var (workspace, note, block, _) = fixture()
        var draft = try NoteTicketDraft(note: note, spaceID: ProjectSpace.personalID, blockID: block.id)
        let before = workspace
        draft.projectID = UUID()
        #expect(throws: TicketWorkError.self) { try workspace.createTicket(from: draft) }
        #expect(workspace == before)
        draft.projectID = nil; draft.title = " \n "
        #expect(throws: TicketWorkError.self) { try workspace.createTicket(from: draft) }
        #expect(workspace == before)
    }

    @Test func archivedMissingAndForeignSourcesCannotCreateTickets() throws {
        var (workspace, note, block, _) = fixture()
        var draft = try NoteTicketDraft(note: note, spaceID: ProjectSpace.personalID, blockID: block.id)
        workspace.spaces[0].notes[0].archived = true
        #expect(throws: TicketWorkError.self) { try workspace.createTicket(from: draft) }
        #expect(workspace.spaces[0].tickets.isEmpty)
        note.archived = true
        #expect(throws: TicketWorkError.self) { try NoteTicketDraft(note: note, spaceID: ProjectSpace.personalID, blockID: block.id) }
        workspace.spaces[0].notes.removeAll()
        #expect(throws: TicketWorkError.self) { try workspace.createTicket(from: draft) }
        note.archived = false
        draft = try NoteTicketDraft(note: note, spaceID: UUID(), blockID: block.id)
        #expect(throws: TicketWorkError.self) { try workspace.createTicket(from: draft) }
    }

    @Test func frozenDraftSurvivesSourceEditsAndAllowsUserEdits() throws {
        var (workspace, note, block, _) = fixture()
        var draft = try NoteTicketDraft(note: note, spaceID: ProjectSpace.personalID, blockID: block.id)
        workspace.spaces[0].notes[0].blocks[0].text = "Updated after the form opened"
        draft.title = "  Better title  "; draft.body += "\n\nAcceptance criteria: retain shortcuts."
        let ticket = try workspace.createTicket(from: draft)
        #expect(ticket.title == "Better title" && ticket.body.contains(block.text))
        #expect(ticket.body.contains("Acceptance criteria") && ticket.linkedNoteIDs == [note.id])
        #expect(workspace.spaces[0].notes[0].blocks[0].text == "Updated after the form opened")
    }

    @Test func codeExcerptsKeepNestedFencesAndDescriptionFormatting() throws {
        let block = SpaceNoteBlock(kind: .code, text: "```swift\nprint(\"Hello\")\n```")
        let note = SpaceNote(title: "Code", blocks: [block])
        let draft = try NoteTicketDraft(note: note, spaceID: ProjectSpace.personalID, blockID: block.id)
        #expect(draft.body == "````\n" + block.text + "\n````")
    }

    @Test func backlinksSurviveRestartAndSpaceMerge() throws {
        var (workspace, note, block, _) = fixture()
        let draft = try NoteTicketDraft(note: note, spaceID: ProjectSpace.personalID, blockID: block.id)
        let ticket = try workspace.createTicket(from: draft)
        let destination = try #require({ workspace.createSpace(name: "Team", color: .blue, symbol: "book.fill") }())
        #expect({ workspace.deleteSpace(ProjectSpace.personalID, movingProjectsTo: destination.id) }())
        let restored = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        #expect(restored.spaces[0].tickets[0].id == ticket.id && restored.spaces[0].tickets[0].linkedNoteIDs == [note.id])
        #expect(restored.spaces[0].notes[0].id == note.id)
    }
}
