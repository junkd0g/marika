import Foundation
import Testing
@testable import MarikaCore

@MainActor
struct DesignWorkspaceTests {
    private func document() -> DesignDocument {
        var document = DesignDocument()
        _ = document.add(.rectangle, in: CGRect(x: 0, y: 0, width: 200, height: 100))
        return document
    }

    @Test func editsPublishSynchronouslyAndInvalidateTheAgentsSnapshot() throws {
        let editor = DesignWorkspace(document: document())
        let previous = try DesignTools.revision(of: editor.document)
        var saved = editor.document
        editor.onChange = { saved = $0 }
        let id = editor.document.nodes[0].id
        editor.edit { $0.move([id], by: CGSize(width: 20, height: 0)) }
        #expect(saved == editor.document)
        #expect(saved.nodes[0].x == 20)
        #expect(throws: DesignToolError.self) {
            try DesignTools.publish(["baseRevision": .string(previous), "design": "{\"nodes\":[]}"], replacing: saved)
        }
    }

    @Test func newEditsAfterUndoDiscardRedoEvenWithinTheCoalescingWindow() {
        let editor = DesignWorkspace(document: document())
        let id = editor.document.nodes[0].id, now = Date()
        editor.edit(coalescing: "x", at: now) { $0.move([id], by: CGSize(width: 5, height: 0)) }
        editor.undo()
        #expect(editor.canRedo)
        editor.edit(coalescing: "x", at: now.addingTimeInterval(0.1)) { $0.move([id], by: CGSize(width: 2, height: 0)) }
        #expect(!editor.canRedo)
        editor.undo()
        #expect(editor.document.nodes[0].x == 0)
    }

    @Test func separatePropertiesAndExternalPublicationsHaveSeparateUndoSteps() {
        let editor = DesignWorkspace(document: document())
        let id = editor.document.nodes[0].id, now = Date()
        editor.edit(coalescing: "width", at: now) { $0.update([id]) { $0.width = 250 } }
        editor.edit(coalescing: "label", at: now) { $0.update([id]) { $0.text = "API" } }
        editor.undo()
        #expect(editor.document.nodes[0].width == 250)
        #expect(editor.document.nodes[0].text == "")
        var published = editor.document
        published.nodes[0].text = "From chat"
        editor.receive(published)
        #expect(editor.externalRevision == 1)
        #expect(!editor.canRedo)
        editor.undo()
        #expect(editor.document.nodes[0].text == "")
        editor.redo()
        #expect(editor.document.nodes[0].text == "From chat")
        editor.receive(editor.document)
        #expect(editor.externalRevision == 1)
    }

    @Test func oneDragUsesOneUndoStepAndProjectsHaveIndependentHistories() {
        let first = DesignWorkspace(document: document()), second = DesignWorkspace(document: document())
        let id = first.document.nodes[0].id
        first.beginInteraction()
        for _ in 0..<5 { first.updateInteraction { $0.move([id], by: CGSize(width: 10, height: 0)) } }
        first.endInteraction()
        #expect(first.document.nodes[0].x == 50)
        #expect(!second.canUndo)
        first.undo()
        #expect(first.document.nodes[0].x == 0)
        #expect(!first.canUndo)
        first.redo()
        #expect(first.document.nodes[0].x == 50)
    }

    @Test func lockedNodesSurviveDeleteAndIgnorePropertyEdits() {
        var document = document()
        let id = document.nodes[0].id
        document.setLocked(id, true)
        let original = document
        document.update([id]) { $0.width = 15; $0.text = "Changed" }
        document.remove([id])
        #expect(document == original)
        #expect(document.duplicate([id]).isEmpty)
        document.setLocked(id, false)
        document.remove([id])
        #expect(document.nodes.isEmpty)
    }

    @Test func invalidManualDimensionsAreNormalizedBeforeTheyReachStorage() throws {
        let editor = DesignWorkspace(document: document())
        let id = editor.document.nodes[0].id
        editor.edit {
            $0.update([id]) { $0.width = -20; $0.height = .infinity; $0.fontSize = -4; $0.opacity = 2 }
        }
        #expect(editor.document.nodes[0].width == DesignDocument.minimumSize)
        #expect(editor.document.nodes[0].height == 100)
        #expect(editor.document.nodes[0].fontSize == 1)
        #expect(editor.document.nodes[0].opacity == 1)
        _ = try JSONEncoder().encode(editor.document)
    }

    @Test func exportsAndFitIgnoreHiddenShapesAndBoundMemoryUse() throws {
        var document = document()
        let visible = document.nodes[0].id
        let hidden = document.add(.rectangle, in: CGRect(x: 90_000, y: 0, width: 200, height: 100))
        document.setHidden(hidden, true)
        #expect(document.visibleBounds == document.nodes[0].frame)
        let plan = try DesignExportPlan(document: document)
        #expect(plan.nodes.map(\.id) == [visible])
        #expect(plan.bounds.width == 232)
        #expect(throws: DesignToolError.self) { try DesignExportPlan(document: document, selection: [hidden]) }
        document.setHidden(hidden, false)
        let large = try DesignExportPlan(document: document)
        #expect(large.bounds.width * large.scale <= 8192)
        #expect(large.bounds.width * large.bounds.height * large.scale * large.scale <= 24_000_001)
    }
}
