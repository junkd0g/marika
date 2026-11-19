import Foundation
import Testing
@testable import MarikaCore

struct DesignSystemTests {
    @Test func sharedColorUpdatesInstancesAndManualEditsDetachOnlyThatLayer() throws {
        var doc = DesignDocument()
        let a = doc.add(.rectangle, in: CGRect(x: 0, y: 0, width: 100, height: 40))
        let b = doc.add(.rectangle, in: CGRect(x: 200, y: 0, width: 100, height: 40))
        var token = DesignColorToken(name: "Accent", color: .blue)
        doc.updateColorToken(token); doc.bindColor(token.id, to: [a, b])
        doc.update([a]) { $0.fill = .black }
        token.color = .white; doc.updateColorToken(token)
        #expect(doc.node(a)?.colorTokenID == nil && doc.node(a)?.fill == .black)
        #expect(doc.node(b)?.colorTokenID == token.id && doc.node(b)?.fill == .white)
        #expect(try JSONDecoder().decode(DesignDocument.self, from: JSONEncoder().encode(doc)) == doc)
    }
    @Test func rowLayoutReflowsChildrenAndKeepsNestedContentsAttached() throws {
        var doc = DesignDocument()
        let frame = doc.add(.frame, in: CGRect(x: 0, y: 0, width: 400, height: 200))
        let a = doc.add(.rectangle, in: CGRect(x: 30, y: 30, width: 100, height: 40))
        let b = doc.add(.rectangle, in: CGRect(x: 200, y: 30, width: 80, height: 40))
        try doc.configureLayout(frame, configuration: DesignAutoLayout(axis: .row, gap: 12, padding: 16))
        #expect(doc.node(a)?.x == 16 && doc.node(b)?.x == 128)
        #expect(doc.node(frame)?.width == 224 && doc.node(frame)?.height == 72)
        doc.update([a]) { $0.width = 120 }; doc.normalize()
        #expect(doc.node(b)?.x == 148 && doc.parents[b] == frame)
        try doc.configureLayout(frame, configuration: nil)
        #expect(doc.node(a)?.layoutParentID == nil)
    }
    @Test func spacingTokensAndLockedLayersBehavePredictably() throws {
        var doc = DesignDocument()
        let frame = doc.add(.frame, in: CGRect(x: 0, y: 0, width: 400, height: 200))
        let a = doc.add(.rectangle, in: CGRect(x: 30, y: 30, width: 100, height: 40))
        let b = doc.add(.rectangle, in: CGRect(x: 200, y: 30, width: 80, height: 40))
        let token = DesignSpacingToken(name: "Space", value: 24)
        doc.designSystem = DesignSystem(); doc.designSystem?.spacing = [token]
        try doc.configureLayout(frame, configuration: DesignAutoLayout(axis: .column, spacingTokenID: token.id))
        #expect(doc.node(b)?.y == 80)
        doc.setLocked(a, true)
        #expect(throws: DesignToolError.self) { try doc.configureLayout(frame, configuration: DesignAutoLayout(axis: .row)) }
        let original = doc.node(a)
        doc.designSystem?.spacing[0].value = 48; doc.normalize()
        #expect(doc.node(a) == original)
    }
    @Test func reusableVariantsPreserveConnectionsAndStableInstanceIdentity() throws {
        var doc = DesignDocument()
        let a = doc.add(.rectangle, in: CGRect(x: 0, y: 0, width: 100, height: 40))
        let b = doc.add(.rectangle, in: CGRect(x: 140, y: 0, width: 100, height: 40))
        doc.connections = [DesignConnection(from: a, to: b, label: "Next")]
        doc.connections?[0].style = .event
        let component = try doc.saveReusableComponent(name: "Steps", variant: "Default", selection: [a, b])
        let first = try #require(doc.designSystem?.components.first?.variants.first?.id)
        doc.update([a]) { $0.fill = .gray }
        _ = try doc.saveReusableComponent(name: "Steps", variant: "Disabled", selection: [a, b], componentID: component)
        let second = try #require(doc.designSystem?.components.first?.variants.last?.id)
        let wrapper = try doc.insertReusableComponent(component, variantID: first, at: CGPoint(x: 400, y: 200))
        #expect(doc.children(of: wrapper).count == 2 && doc.connections?.last?.style == .event)
        try doc.switchComponentVariant(wrapper, variantID: second)
        #expect(doc.node(wrapper)?.reusableInstance?.variantID == second)
        #expect(doc.children(of: wrapper).count == 2)
        #expect(Set(doc.nodes.map(\.id)).count == doc.nodes.count)
    }
    @Test func duplicatingAutomaticFramesRemapsParentsAndConnectionStyles() throws {
        var doc = DesignDocument()
        let frame = doc.add(.frame, in: CGRect(x: 0, y: 0, width: 400, height: 200))
        let a = doc.add(.rectangle, in: CGRect(x: 20, y: 20, width: 100, height: 40))
        let b = doc.add(.rectangle, in: CGRect(x: 180, y: 20, width: 100, height: 40))
        try doc.configureLayout(frame, configuration: DesignAutoLayout(axis: .row))
        doc.connections = [DesignConnection(from: a, to: b, label: "Next")]
        doc.connections?[0].style = .event
        let copies = doc.duplicate([frame, a, b], offset: 500)
        doc.normalize()
        let copiedFrame = try #require(copies.first { doc.node($0)?.kind == .frame })
        #expect(doc.children(of: copiedFrame).count == 2)
        #expect(doc.children(of: frame).count == 2)
        #expect(doc.connections?.last?.style == .event)
        #expect(doc.node(copiedFrame)?.x == 500)
    }
    @Test func explicitParentCyclesNeverEnterLayerTraversal() {
        var doc = DesignDocument()
        let a = doc.add(.frame, in: CGRect(x: 0, y: 0, width: 200, height: 200))
        let b = doc.add(.frame, in: CGRect(x: 300, y: 0, width: 200, height: 200))
        doc.update([a]) { $0.layoutParentID = b }; doc.update([b]) { $0.layoutParentID = a }
        #expect(doc.layerHierarchy().count == 2)
    }
}
