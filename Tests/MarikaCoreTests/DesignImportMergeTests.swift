import Foundation
import Testing
@testable import MarikaCore

struct DesignImportMergeTests {
    private func fixture() throws -> (DesignImportBatch, DesignDocument, DesignDocument, UUID) {
        var source = DesignDocument()
        let button = source.add(.rectangle, in: CGRect(x: 0, y: 0, width: 100, height: 40))
        source.update([button]) { $0.name = "Save"; $0.text = "Save" }
        let proposal = DesignImportProposal(summary: "Settings", notes: [], document: source)
        let batchID = UUID(), result = try proposal.appending(to: DesignDocument(), batchID: batchID)
        let batch = DesignImportBatch(id: batchID, name: "Settings", baseline: result.document, files: [])
        return (batch, result.document, source, result.document.nodes.first { $0.name == "Save" }!.id)
    }
    @Test func updatesStableIdentityAndPreservesOutsideScope() throws {
        let (batch, initial, source, button) = try fixture()
        var current = initial, incoming = source
        let outside = current.add(.text, in: CGRect(x: 900, y: 0, width: 200, height: 30))
        incoming.nodes[0].text = "Save changes"
        let plan = try DesignImportMerge(batch: batch, current: current, targets: Set(initial.nodes.map(\.id)), proposal: incoming)
        #expect(plan.conflicts.isEmpty && plan.changed == 1)
        let result = try plan.applying()
        #expect(result.document.node(button)?.text == "Save changes")
        #expect(result.document.node(outside) == current.node(outside))
        #expect(result.document.nodes.count == current.nodes.count)
    }
    @Test func manualEditsAndDeletesRequireExplicitResolution() throws {
        let (batch, initial, source, button) = try fixture()
        var current = initial, incoming = source
        current.update([button]) { $0.text = "Manual" }
        incoming.nodes[0].text = "Generated"
        let ids = Set(initial.nodes.map(\.id))
        var plan = try DesignImportMerge(batch: batch, current: current, targets: ids, proposal: incoming)
        #expect(plan.conflicts.map(\.id) == [button])
        #expect(try plan.applying().document.node(button)?.text == "Manual")
        #expect(try plan.applying(useGenerated: [button]).document.node(button)?.text == "Generated")
        current.nodes.removeAll { $0.id == button }
        plan = try DesignImportMerge(batch: batch, current: current, targets: ids, proposal: incoming)
        #expect(plan.conflicts.map(\.id) == [button])
        #expect(try plan.applying().document.node(button) == nil)
    }
    @Test func lockedLayersStayLockedEvenWhenOverrideRequested() throws {
        let (batch, initial, source, button) = try fixture()
        var current = initial, incoming = source
        current.update([button]) { $0.isLocked = true }
        incoming.nodes[0].text = "New"
        let plan = try DesignImportMerge(batch: batch, current: current, targets: [button], proposal: incoming)
        #expect(plan.conflicts.first?.allowsOverride == false)
        #expect(try plan.applying(useGenerated: [button]).document.node(button) == current.node(button))
    }
}
