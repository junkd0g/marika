import Foundation
import Testing

@testable import MarikaCore

struct ProjectTabTests {
    @Test func legacyLayoutsOpenTheirSelectedAndSplitViews() throws {
        let layout = try JSONDecoder().decode(ProjectLayout.self, from: Data(#"{"panel":"Code","secondary":"Browser"}"#.utf8))
        #expect(layout.openTabs == [.conversation, .code, .browser])
        #expect(layout.panel == .code && layout.secondary == .browser)
        let empty = try JSONDecoder().decode(ProjectLayout.self, from: Data("{}".utf8))
        #expect(empty.openTabs == [.conversation])
    }

    @Test func savedTabsAreUniqueAndKeepChatFirst() throws {
        let layout = try JSONDecoder().decode(ProjectLayout.self,
            from: Data(#"{"panel":"Stats","openTabs":["Code","Conversation","Code","Stats","Conversation"]}"#.utf8))
        #expect(layout.openTabs == [.conversation, .code, .stats])
        #expect(layout.panel == .stats)
    }

    @Test func openingAnExistingTabReusesItAndSwapsASplit() {
        var layout = ProjectLayout()
        layout.openTab(.code)
        layout.secondary = .browser
        layout.openTab(.browser)
        layout.openTab(.browser)
        #expect(layout.panel == .browser && layout.secondary == .code)
        #expect(layout.openTabs == [.conversation, .code, .browser])
        // Older callers that assign a panel directly also add a visible tab.
        layout.panel = .stats
        #expect(layout.openTabs == [.conversation, .code, .browser, .stats])
    }

    @Test func closingTabsKeepsEditorDraftsAndBrowserPages() {
        var layout = ProjectLayout()
        layout.files = [EditorFileState(path: "App.swift", draft: "unsaved", baseText: "original", line: 8)]
        layout.selectedFile = "App.swift"
        layout.browserURLs = ["http://localhost:3000"]
        layout.openTab(.code)
        layout.openTab(.stats)
        let closed = layout.closeTab(.stats)
        #expect(closed)
        #expect(layout.panel == .code && layout.openTabs == [.conversation, .code])
        let closedCode = layout.closeTab(.code)
        #expect(closedCode)
        #expect(layout.panel == .conversation && layout.openTabs == [.conversation])
        #expect(layout.files.first?.draft == "unsaved" && layout.selectedFile == "App.swift")
        #expect(layout.browserURLs == ["http://localhost:3000"])
        let closedChat = layout.closeTab(.conversation)
        #expect(!closedChat)
    }

    @Test func closingEitherSideOfASplitLeavesAUsableWorkspace() {
        var layout = ProjectLayout()
        layout.openTab(.code)
        layout.secondary = .browser
        let closedPrimary = layout.closeTab(.code)
        #expect(closedPrimary)
        #expect(layout.panel == .browser && layout.secondary == nil)
        layout.secondary = .stats
        let closedSecondary = layout.closeTab(.stats)
        #expect(closedSecondary)
        #expect(layout.panel == .browser && layout.secondary == nil)
        #expect(layout.openTabs == [.conversation, .browser])
    }

    @Test func tabOrderAndKeyboardCyclingRespectThePinnedChat() {
        var layout = ProjectLayout()
        layout.openTab(.code)
        layout.openTab(.stats)
        let moved = layout.moveTab(.stats, offset: -1)
        #expect(moved)
        #expect(layout.openTabs == [.conversation, .stats, .code])
        #expect(layout.adjacentTab(1) == .code && layout.adjacentTab(-1) == .conversation)
        layout.openTab(.conversation)
        #expect(layout.adjacentTab(-1) == .code)
        let movedChat = layout.moveTab(.conversation, offset: 1)
        let movedBeforeChat = layout.moveTab(.stats, offset: -1)
        #expect(!movedChat && !movedBeforeChat)
        layout.closeOtherTabs(keeping: .stats)
        #expect(layout.openTabs == [.conversation, .stats] && layout.panel == .stats)
        #expect(layout.secondary == nil)
    }

    @Test func eachProjectRestoresItsOwnOpenTabsAndClosedTabsStayClosed() async throws {
        var first = Project(path: "/first"), second = Project(path: "/second")
        var firstLayout = ProjectLayout(), secondLayout = ProjectLayout()
        firstLayout.openTab(.code); firstLayout.openTab(.stats)
        _ = firstLayout.closeTab(.code)
        secondLayout.openTab(.browser)
        first.layout = firstLayout; second.layout = secondLayout
        let workspace = Workspace(projects: [first, second])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root)
        try await store.save(workspace)
        let restored = try await store.loadWorkspace()
        #expect(restored == workspace)
        #expect(restored.projects[0].layout?.openTabs == [.conversation, .stats])
        #expect(restored.projects[0].layout?.panel == .stats)
        #expect(restored.projects[1].layout?.openTabs == [.conversation, .browser])
        #expect(restored.projects[1].layout?.panel == .browser)
    }
}
