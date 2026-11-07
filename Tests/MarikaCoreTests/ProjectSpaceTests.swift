import Foundation
import Testing

@testable import MarikaCore

struct ProjectSpaceTests {
    @Test func olderWorkspacesKeepEveryProjectAndConversation() throws {
        let first = UUID(), second = UUID(), session = UUID()
        let data = Data("""
            {"projects":[{"id":"\(first)","path":"/first","name":"First"},
                         {"id":"\(second)","path":"/second","name":"Second"}],
             "sessions":[{"id":"\(session)","projectID":"\(second)","agent":"codex","title":"A saved chat",
                           "createdAt":0,"updatedAt":0,"mode":"ask","draft":{"text":"Unsent","images":[]}}],
             "selectedProjectID":"\(second)"}
            """.utf8)
        let workspace = try JSONDecoder().decode(Workspace.self, from: data)
        #expect(workspace.spaces == [.personal])
        #expect(workspace.projects(in: ProjectSpace.personalID).map(\.id) == [first, second])
        #expect(workspace.preferredProject(in: ProjectSpace.personalID)?.id == second)
        #expect(workspace.sessions.first?.draft?.text == "Unsent")
        #expect(workspace.sessions.first?.id == session)
    }

    @Test func eachSpaceRemembersItsOwnSelectionAcrossSaving() async throws {
        let work = ProjectSpace(name: "Work", color: .violet)
        let first = Project(path: "/first"), second = Project(path: "/second")
        var third = Project(path: "/third")
        third.spaceID = work.id
        var workspace = Workspace(projects: [first, second, third], spaces: [.personal, work])
        workspace.rememberProject(second.id)
        let openedWork = workspace.activateSpace(work.id)
        #expect(openedWork)
        #expect(workspace.selectedProjectID == third.id)
        workspace.rememberProject(third.id)
        let openedPersonal = workspace.activateSpace(ProjectSpace.personalID)
        #expect(openedPersonal)
        #expect(workspace.selectedProjectID == second.id)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root)
        try await store.save(workspace)
        var saved = try await store.loadWorkspace()
        #expect(saved == workspace)
        let restoredWork = saved.activateSpace(work.id)
        #expect(restoredWork)
        #expect(saved.selectedProjectID == third.id)
        let restoredPersonal = saved.activateSpace(ProjectSpace.personalID)
        #expect(restoredPersonal)
        #expect(saved.selectedProjectID == second.id)
    }

    @Test func emptySpaceStaysSelectedInsteadOfOpeningAnotherSpacesProject() throws {
        let empty = ProjectSpace(name: "Ideas", color: .teal)
        var workspace = Workspace(projects: [Project(path: "/first")], spaces: [.personal, empty])
        workspace.rememberProject(workspace.projects[0].id)
        let opened = workspace.activateSpace(empty.id)
        #expect(opened)
        #expect(workspace.selectedProjectID == nil)
        let saved = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        #expect(saved.selectedSpace.id == empty.id)
        #expect(saved.preferredProject(in: empty.id) == nil)
    }

    @Test func movingProjectsKeepsDraftsAndDoesNotSelectTheDestinationSpace() {
        let work = ProjectSpace(name: "Work")
        let first = Project(path: "/first"), second = Project(path: "/second")
        let session = SessionMeta(projectID: first.id, agent: .claude, draft: SessionDraft(text: "Keep this draft"))
        var workspace = Workspace(projects: [first, second], sessions: [session], spaces: [.personal, work])
        workspace.rememberProject(first.id)
        let moved = workspace.moveProject(first.id, to: work.id)
        #expect(moved)
        #expect(workspace.selectedSpace.id == ProjectSpace.personalID)
        #expect(workspace.selectedProjectID == second.id)
        #expect(workspace.projects(in: work.id).map(\.id) == [first.id])
        #expect(workspace.sessions == [session])
        let invalidMove = workspace.moveProject(first.id, to: UUID())
        let duplicateMove = workspace.moveProject(first.id, to: work.id)
        #expect(!invalidMove)
        #expect(!duplicateMove)
    }

    @Test func deletingASpaceMovesProjectsAndPreservesTheOpenProject() {
        let work = ProjectSpace(name: "Work")
        var first = Project(path: "/first")
        first.spaceID = work.id
        let second = Project(path: "/second")
        let session = SessionMeta(projectID: first.id, agent: .codex)
        var workspace = Workspace(projects: [first, second], sessions: [session], spaces: [.personal, work])
        workspace.rememberProject(first.id)
        let deleted = workspace.deleteSpace(work.id, movingProjectsTo: ProjectSpace.personalID)
        #expect(deleted)
        #expect(workspace.spaces.count == 1)
        #expect(workspace.projects.count == 2)
        #expect(workspace.projects.allSatisfy { $0.spaceID == ProjectSpace.personalID })
        #expect(workspace.selectedProjectID == first.id)
        #expect(workspace.selectedSpace.lastProjectID == first.id)
        #expect(workspace.sessions == [session])
        let deletedLast = workspace.deleteSpace(ProjectSpace.personalID, movingProjectsTo: ProjectSpace.personalID)
        #expect(!deletedLast)
    }

    @Test func staleMembershipAndSelectionsAreRecoveredWithoutLosingProjects() {
        var first = Project(path: "/first"), second = Project(path: "/second")
        first.spaceID = UUID(); second.spaceID = nil
        let work = ProjectSpace(name: "Work", lastProjectID: UUID())
        let workspace = Workspace(projects: [first, second], spaces: [work, work], selectedSpaceID: UUID())
        #expect(workspace.spaces.count == 1)
        #expect(workspace.selectedSpace.id == work.id)
        #expect(workspace.selectedSpace.lastProjectID == nil)
        #expect(workspace.projects(in: work.id).count == 2)
        let empty = Workspace(spaces: [])
        #expect(empty.spaces == [.personal])
    }

    @Test func editingAndReorderingDoNotChangeMembershipOrTheActiveSpace() throws {
        let project = Project(path: "/first")
        var workspace = Workspace(projects: [project])
        let created = workspace.createSpace(name: " Work ", color: .teal, symbol: "briefcase.fill")
        let work = try #require(created)
        #expect(work.name == "Work")
        workspace.rememberProject(project.id)
        let edited = workspace.editSpace(work.id, name: "Studio", color: .rose, symbol: "hammer.fill")
        let reordered = workspace.reorderSpace(work.id, offset: -1)
        #expect(edited)
        #expect(reordered)
        #expect(workspace.spaces.first?.name == "Studio")
        #expect(workspace.selectedSpace.id == ProjectSpace.personalID)
        #expect(workspace.projects(in: ProjectSpace.personalID).map(\.id) == [project.id])
        let invalidEdit = workspace.editSpace(work.id, name: "  ", color: .blue, symbol: "globe")
        let longName = workspace.createSpace(name: String(repeating: "A", count: 41), color: .blue, symbol: "globe")
        let blankName = workspace.createSpace(name: " \n ", color: .blue, symbol: "globe")
        let invalidSelection = workspace.activateSpace(UUID())
        #expect(!invalidEdit)
        #expect(longName == nil)
        #expect(blankName == nil)
        #expect(!invalidSelection)
    }
}
