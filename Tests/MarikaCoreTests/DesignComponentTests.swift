import Foundation
import Testing
@testable import MarikaCore

struct DesignComponentTests {
    @Test func presetsAreEditableAndKeepTheirRoleAcrossCopyAndPersistence() throws {
        var doc = DesignDocument()
        for (index, component) in DesignComponent.allCases.enumerated() {
            let center = CGPoint(x: Double(index) * 300, y: -100)
            let id = doc.addComponent(component, centeredAt: center)
            let node = try #require(doc.node(id))
            #expect(node.center == center)
            #expect(node.kind == .rectangle && node.component == component)
            #expect(node.text == component.title && node.description?.contains("placeholder") == true)
            #expect(!node.isLocked && !node.isHidden && node.fontSize > 0)
            #expect(node.stroke != nil && !component.symbol.isEmpty)
        }
        let first = doc.nodes[0].id, second = doc.nodes[1].id
        doc.connect(first, second, label: "HTTPS")
        let copied = doc.duplicate([first, second])
        #expect(doc.node(copied[0])?.component == doc.node(first)?.component)
        #expect(doc.connections?.count == 2)
        #expect(try JSONDecoder().decode(DesignDocument.self, from: JSONEncoder().encode(doc)) == doc)
        let another = doc.addComponent(.database, centeredAt: .zero)
        #expect(doc.node(another)?.name == "Database 2")
    }

    @Test func agentsCanCreatePreserveAndClearComponentRoles() throws {
        let empty = DesignDocument()
        let doc = try DesignTools.publish(["baseRevision": .string(DesignTools.revision(of: empty)),
            "design": #"{"nodes":[{"id":"db","component":"database","text":"Orders"}]}"#], replacing: empty)
        let node = try #require(doc.nodes.first)
        #expect(node.component == .database && node.text == "Orders")
        #expect(node.fill == DesignComponent.database.makeNode(centeredAt: .zero).fill)
        #expect(try DesignTools.referencePrompt(doc).contains("Engineering component: Database (database)"))
        let raw = try DesignTools.snapshot(doc)["document"]
        let same = try DesignTools.publish(["baseRevision": .string(DesignTools.revision(of: doc)),
            "design": .string(String(decoding: try #require(raw).serialized(), as: UTF8.self))], replacing: doc)
        #expect(same == doc)
        var withoutDescription = doc
        withoutDescription.update([node.id]) { $0.description = nil }
        let snapshot = try DesignTools.snapshot(withoutDescription)
        let restored = try DesignTools.publish(["baseRevision": try #require(snapshot["baseRevision"]),
            "design": .string(String(decoding: try #require(snapshot["document"]).serialized(), as: UTF8.self))], replacing: withoutDescription)
        #expect(restored == withoutDescription)
        let id = node.id.uuidString
        let preserved = try DesignTools.publish(["baseRevision": .string(DesignTools.revision(of: doc)),
            "design": .string("{\"nodes\":[{\"id\":\"\(id)\",\"text\":\"Renamed\"}]}")], replacing: doc)
        #expect(preserved.nodes[0].component == .database)
        #expect(preserved.nodes[0].description == node.description)
        let cleared = try DesignTools.publish(["baseRevision": .string(DesignTools.revision(of: preserved)),
            "design": .string("{\"nodes\":[{\"id\":\"\(id)\",\"component\":\"\"}]}")], replacing: preserved)
        #expect(cleared.nodes[0].component == nil)
    }

    @Test(arguments: ["unknown", "database\",\"kind\":\"line", "queue\",\"kind\":\"text"])
    func rejectsInvalidRolesAndIncompatibleShapes(_ value: String) throws {
        let empty = DesignDocument()
        #expect(throws: DesignToolError.self) {
            try DesignTools.publish(["baseRevision": .string(DesignTools.revision(of: empty)),
                "design": .string("{\"nodes\":[{\"id\":\"a\",\"component\":\"\(value)\"}]}")], replacing: empty)
        }
    }

    @Test func oldShapesHaveNoRoleAndNormalizingTextRemovesItsBadge() throws {
        var node = DesignComponent.api.makeNode(centeredAt: .zero)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(node)) as? [String: Any])
        object.removeValue(forKey: "component")
        let old = try JSONDecoder().decode(DesignNode.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.component == nil)
        node.kind = .text
        node.normalize()
        #expect(node.component == nil)
    }
}
