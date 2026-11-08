import Foundation
import Testing

@testable import MarikaCore

struct ProjectTabTests {
    @Test func draggedViewsSplitAtEachEdgeAndPersist() throws {
        for edge in ProjectSplitEdge.allCases {
            var layout = ProjectLayout()
            layout.files = [EditorFileState(path: "App.swift", draft: "unsaved", baseText: "original")]
            layout.browserURLs = ["http://localhost:3000"]
            let split = layout.splitTab(.code, at: edge)
            #expect(split)
            #expect(layout.panel == (edge.leading ? .code : .conversation))
            #expect(layout.secondary == (edge.leading ? .conversation : .code))
            #expect(layout.stacked == edge.stacked && layout.splitFraction == 0.5)
            #expect(layout.openTabs.contains(.code))
            #expect(layout.files.first?.draft == "unsaved" && layout.browserURLs == ["http://localhost:3000"])
            let restored = try JSONDecoder().decode(ProjectLayout.self, from: JSONEncoder().encode(layout))
            #expect(restored == layout)
        }
    }

    @Test func draggingTheActiveViewRetainsTheOtherPaneAndCanReverseTheSplit() {
        var layout = ProjectLayout()
        layout.openTab(.code)
        layout.secondary = .browser
        let movedRight = layout.splitTab(.code, at: .right)
        #expect(movedRight)
        #expect(layout.panel == .browser && layout.secondary == .code)
        let movedTop = layout.splitTab(.code, at: .top)
        #expect(movedTop)
        #expect(layout.panel == .code && layout.secondary == .browser && layout.stacked)
        // Replacing a split keeps the old view available as a tab.
        let replaced = layout.splitTab(.stats, at: .bottom)
        #expect(replaced)
        #expect(layout.panel == .code && layout.secondary == .stats)
        #expect(layout.openTabs.contains(.browser))
    }

    @Test func draggingASingleViewCannotCreateASplitWithItself() {
        var layout = ProjectLayout()
        let noPartner = layout.splitTab(.conversation, at: .left)
        #expect(!noPartner)
        #expect(layout.secondary == nil)
        layout.openTab(.code)
        let split = layout.splitTab(.code, at: .left)
        #expect(split)
        #expect(layout.panel == .code && layout.secondary == .conversation)
    }

    @Test func splitDropTargetsOnlyAcceptWorkspaceEdges() {
        #expect(ProjectSplitEdge.target(x: 30, y: 300, width: 1000, height: 600) == .left)
        #expect(ProjectSplitEdge.target(x: 970, y: 300, width: 1000, height: 600) == .right)
        #expect(ProjectSplitEdge.target(x: 500, y: 10, width: 1000, height: 600) == .top)
        #expect(ProjectSplitEdge.target(x: 500, y: 590, width: 1000, height: 600) == .bottom)
        #expect(ProjectSplitEdge.target(x: 500, y: 300, width: 1000, height: 600) == nil)
        #expect(ProjectSplitEdge.target(x: -1, y: 0, width: 1000, height: 600) == nil)
        #expect(ProjectSplitEdge.target(x: 0, y: 0, width: 0, height: 0) == nil)
    }

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
