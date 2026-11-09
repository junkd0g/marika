import Foundation
import Testing
@testable import MarikaCore

struct SpaceContentTests {
    @Test func oldSpacesLoadWithEmptyContent() throws {
        let space = try JSONDecoder().decode(ProjectSpace.self, from: Data("""
        {"id":"\(UUID())","name":"Work","color":"violet","symbol":"briefcase.fill"}
        """.utf8))
        #expect(space.notes.isEmpty && space.tickets.isEmpty && space.section == .projects)
        #expect(space.nextTicketNumber == 1 && !space.ticketPrefix.isEmpty)
    }

    @Test func notesAndTicketsAreStrictlyScopedToTheirSpace() throws {
        let work = ProjectSpace(name: "Work")
        var workspace = Workspace(spaces: [.personal, work])
        let note = try #require({ workspace.createNote(in: work.id) }())
        let ticket = try #require({ workspace.createTicket(in: work.id) }())
        #expect({ !workspace.updateNote(note.id, in: ProjectSpace.personalID) { $0.title = "Wrong" } }())
        #expect({ !workspace.updateTicket(ticket.id, in: ProjectSpace.personalID) { $0.title = "Wrong" } }())
        #expect(workspace.spaces[0].notes.isEmpty && workspace.spaces[0].tickets.isEmpty)
        #expect({ workspace.createNote(in: UUID()) == nil && workspace.createTicket(in: UUID()) == nil }())
    }

    @Test func blockContentAndArchiveArePreservedThroughStorage() async throws {
        var workspace = Workspace()
        let note = try #require({ workspace.createNote(in: ProjectSpace.personalID) }())
        #expect({ workspace.updateNote(note.id, in: ProjectSpace.personalID) {
            $0.title = "Release plan"; $0.pinned = true; $0.archived = true
            $0.blocks = [SpaceNoteBlock(kind: .heading, text: "Ship"), SpaceNoteBlock(kind: .checklist, text: "Run tests", checked: true), SpaceNoteBlock(kind: .code, text: "swift test")]
        } }())
        let ticket = try #require({ workspace.createTicket(in: ProjectSpace.personalID) }())
        #expect({ workspace.updateTicket(ticket.id, in: ProjectSpace.personalID) {
            $0.title = "Fix navigation"; $0.body = "## Acceptance criteria\n- Keep shortcuts"; $0.assignee = "Jordan"
            $0.kind = .bug; $0.priority = .urgent; $0.status = .inProgress; $0.archived = true
        } }())
        workspace.spaces[0].section = .notes
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("space-content-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root); try await store.save(workspace)
        let loaded = try await store.loadWorkspace()
        var expected = workspace
        for index in expected.spaces[0].notes.indices {
            #expect(abs(expected.spaces[0].notes[index].updatedAt.timeIntervalSince(loaded.spaces[0].notes[index].updatedAt)) < 1)
            expected.spaces[0].notes[index].createdAt = loaded.spaces[0].notes[index].createdAt
            expected.spaces[0].notes[index].updatedAt = loaded.spaces[0].notes[index].updatedAt
        }
        for index in expected.spaces[0].tickets.indices {
            #expect(abs(expected.spaces[0].tickets[index].updatedAt.timeIntervalSince(loaded.spaces[0].tickets[index].updatedAt)) < 1)
            expected.spaces[0].tickets[index].createdAt = loaded.spaces[0].tickets[index].createdAt
            expected.spaces[0].tickets[index].updatedAt = loaded.spaces[0].tickets[index].updatedAt
        }
        #expect(loaded == expected)
        #expect(loaded.spaces[0].notes[0].markdown.contains("- [x] Run tests"))
        #expect(loaded.spaces[0].tickets[0].key == ticket.key)
        #expect(loaded.spaces[0].section == .notes)
    }

    @Test func renamingASpaceDoesNotLoseNotesTicketsOrChangeKeys() throws {
        var workspace = Workspace()
        let note = try #require({ workspace.createNote(in: ProjectSpace.personalID) }())
        let ticket = try #require({ workspace.createTicket(in: ProjectSpace.personalID) }())
        workspace.spaces[0].section = .tickets
        #expect({ workspace.editSpace(ProjectSpace.personalID, name: "Team", color: .rose, symbol: "book.fill") }())
        #expect(workspace.spaces[0].notes.first?.id == note.id)
        #expect(workspace.spaces[0].tickets.first?.key == ticket.key && workspace.spaces[0].section == .tickets)
    }

    @Test func ticketKeysNeverCollideOrGetReusedAfterMergeAndRecreation() throws {
        var workspace = Workspace()
        let one = try #require({ workspace.createSpace(name: "Work", color: .blue, symbol: "book.fill") }())
        let two = try #require({ workspace.createSpace(name: "Work", color: .teal, symbol: "book.fill") }())
        let first = try #require({ workspace.createTicket(in: one.id) }()), second = try #require({ workspace.createTicket(in: two.id) }())
        #expect(first.key != second.key)
        #expect({ workspace.deleteSpace(one.id, movingProjectsTo: two.id) }())
        #expect(workspace.spaces.first { $0.id == two.id }?.tickets.map(\.key).contains(first.key) == true)
        let recreated = try #require({ workspace.createSpace(name: "Work", color: .blue, symbol: "book.fill") }())
        let third = try #require({ workspace.createTicket(in: recreated.id) }())
        #expect(Set([first.key, second.key, third.key]).count == 3)
    }

    @Test func deletingASpaceMovesAllContentAndKeepsProjectLinks() throws {
        let source = ProjectSpace(name: "Work"), destination = ProjectSpace(name: "Team")
        var project = Project(path: "/project"); project.spaceID = source.id
        var workspace = Workspace(projects: [project], spaces: [source, destination])
        let note = try #require({ workspace.createNote(in: source.id) }()), ticket = try #require({ workspace.createTicket(in: source.id) }())
        #expect({ workspace.updateTicket(ticket.id, in: source.id) { $0.projectID = project.id } }())
        #expect({ workspace.deleteSpace(source.id, movingProjectsTo: destination.id) }())
        #expect(workspace.spaces[0].notes.first?.id == note.id)
        #expect(workspace.spaces[0].tickets.first?.projectID == project.id)
        #expect(workspace.spaces[0].tickets.first?.key == ticket.key)
    }

    @Test func projectLinksCannotCrossSpacesAndDetachWhenProjectMoves() throws {
        let work = ProjectSpace(name: "Work")
        let project = Project(path: "/project")
        var workspace = Workspace(projects: [project], spaces: [.personal, work])
        let ticket = try #require({ workspace.createTicket(in: work.id) }())
        #expect({ workspace.updateTicket(ticket.id, in: work.id) { $0.projectID = project.id } }())
        #expect(workspace.spaces[1].tickets[0].projectID == nil)
        let personal = try #require({ workspace.createTicket(in: ProjectSpace.personalID) }())
        #expect({ workspace.updateTicket(personal.id, in: ProjectSpace.personalID) { $0.projectID = project.id } }())
        #expect({ workspace.moveProject(project.id, to: work.id) }())
        #expect(workspace.spaces[0].tickets[0].projectID == nil)
    }

    @Test func removingTheLastBlockKeepsTheNoteEditableAndArchiveCanBeRestored() throws {
        var workspace = Workspace()
        let note = try #require({ workspace.createNote(in: ProjectSpace.personalID) }())
        #expect({ workspace.updateNote(note.id, in: ProjectSpace.personalID) { $0.blocks = []; $0.archived = true } }())
        #expect(workspace.spaces[0].notes[0].blocks.count == 1)
        #expect({ workspace.updateNote(note.id, in: ProjectSpace.personalID) { $0.archived = false } }())
        #expect(!workspace.spaces[0].notes[0].archived)
    }
}
