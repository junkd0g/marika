import Foundation
import Testing
@testable import MarikaCore

struct DesignToolsTests {
    private var architecture: String {
        ##"{"title":"Service architecture","nodes":[{"id":"web","name":"Web app","text":"Web app","fill":"#E8EFFFAA"},{"id":"api","name":"API","text":"API service","x":380,"y":0,"width":240,"height":120}],"connections":[{"from":"web","to":"api","label":"HTTPS"}]}"##
    }

    private func publish(_ json: String, replacing current: DesignDocument = DesignDocument()) throws -> DesignDocument {
        try DesignTools.publish(["design": .string(json), "baseRevision": .string(DesignTools.revision(of: current))], replacing: current)
    }

    @Test func chatToolsAreDiscoverableAndReadIsMarkedReadOnly() throws {
        #expect(AgentTaskTools.handles("project_get_design"))
        #expect(AgentTaskTools.handles("project_publish_design"))
        let read = try #require(AgentTaskTools.definitions.first { $0["name"]?.string == "project_get_design" })
        let write = try #require(AgentTaskTools.definitions.first { $0["name"]?.string == "project_publish_design" })
        #expect(read["annotations"]?["readOnlyHint"]?.bool == true)
        #expect(write["annotations"]?["readOnlyHint"]?.bool == false)
        #expect(AgentTaskTools.instructions.contains("native visual Design app"))
    }

    @Test func architecturePublishesAsEditableShapesAndAttachedArrows() throws {
        let doc = try publish(architecture)
        #expect(doc.title == "Service architecture")
        #expect(doc.nodes.map(\.text) == ["Web app", "API service"])
        #expect(doc.nodes[0].frame == CGRect(x: 0, y: 0, width: 220, height: 100))
        #expect(doc.nodes[1].width == 240)
        #expect(doc.nodes[0].fill.alpha == Double(170) / 255)
        let edge = try #require(doc.connections?.first)
        #expect(edge.from == doc.nodes[0].id)
        #expect(edge.to == doc.nodes[1].id)
        #expect(edge.label == "HTTPS")
        #expect(try JSONDecoder().decode(DesignDocument.self, from: JSONEncoder().encode(doc)) == doc)
    }

    @Test func readThenPublishPreservesIDsStylesAndConnections() throws {
        let original = try publish(architecture)
        let snapshot = try DesignTools.snapshot(original)
        let result = try DesignTools.publish(["baseRevision": try #require(snapshot["baseRevision"]),
            "design": .string(String(decoding: try #require(snapshot["document"]).serialized(), as: UTF8.self))], replacing: original)
        #expect(result == original)
        #expect(try DesignTools.revision(of: result) == DesignTools.revision(of: original))
    }

    @Test func newerManualEditsRejectAStaleAgentUpdate() throws {
        var current = try publish(architecture)
        let oldRevision = try DesignTools.revision(of: current)
        let id = try #require(current.nodes.first?.id)
        current.move([id], by: CGSize(width: 35, height: 20))
        #expect(throws: DesignToolError.self) {
            try DesignTools.publish(["design": .string(architecture), "baseRevision": .string(oldRevision)], replacing: current)
        }
        #expect(current.nodes[0].x == 35)
        #expect(throws: DesignToolError.self) { try DesignTools.publish(["design": .string(architecture)], replacing: current) }
    }

    @Test(arguments: [
        #"{"nodes":[{"id":"a"},{"id":"a"}]}"#,
        #"{"nodes":[{"id":"a","width":-1}]}"#,
        #"{"nodes":[{"id":"a","opacity":4}]}"#,
        #"{"nodes":[{"id":"a","fill":"red"}]}"#,
        #"{"nodes":[{"id":"a","kind":"iframe"}]}"#,
        #"{"nodes":[{"id":"a"}],"connections":[{"from":"a","to":"missing"}]}"#,
        #"{"nodes":[{"id":"a"}],"connections":[{"from":"a","to":"a"}]}"#,
        #"{"nodes":[{"id":"a","fill":{"red":2,"green":0,"blue":0,"alpha":1}}]}"#,
        #"{"nodes":[{"id":"a","rotation":9999}]}"#,
        #"{"nodes":[{"id":"a","kind":"polygon","sides":2}]}"#,
        #"{"nodes":[{"id":"a","strokeStyle":"wavy"}]}"#,
        #"{"nodes":[{"id":"a","shadow":{"blur":-1}}]}"#
    ])
    func invalidDocumentsAreRejected(_ json: String) throws {
        #expect(throws: (any Error).self) { try publish(json) }
    }

    @Test func oldCanvasesDecodeAndConnectionsFollowManualEditing() throws {
        let old = try JSONDecoder().decode(DesignDocument.self, from: Data(#"{"nodes":[]}"#.utf8))
        #expect(old == DesignDocument())
        var doc = try publish(architecture)
        let first = doc.nodes[0].id
        let edge = try #require(doc.connections?.first)
        let start = try #require(edge.route(in: doc.nodes)?.first)
        doc.move([first], by: CGSize(width: 20, height: 30))
        #expect(edge.route(in: doc.nodes)?.first == CGPoint(x: start.x + 20, y: start.y + 30))
        let copies = doc.duplicate(Set(doc.nodes.map(\.id)))
        #expect(copies.count == 2)
        #expect(doc.connections?.count == 2)
        let copiedEdge = try #require(doc.connections?.last)
        #expect(copies.contains(copiedEdge.from) && copies.contains(copiedEdge.to))
        doc.remove([first])
        #expect(doc.connections?.count == 1)
        #expect(doc.connections?.first == copiedEdge)
    }

    @Test func chatCannotReplaceOrDeleteLockedShapes() throws {
        var current = try publish(architecture)
        current.setLocked(current.nodes[0].id, true)
        #expect(throws: DesignToolError.self) { try publish(architecture, replacing: current) }
        let snapshot = try DesignTools.snapshot(current)
        let unchanged = try DesignTools.publish(["baseRevision": try #require(snapshot["baseRevision"]),
            "design": .string(String(decoding: try #require(snapshot["document"]).serialized(), as: UTF8.self))], replacing: current)
        #expect(unchanged == current)
    }

    @Test func newShapesAndStylesPublishAndSurviveAReadPublishRoundTrip() throws {
        let doc = try publish(##"{"nodes":[{"id":"lane","kind":"frame","width":600,"height":300},{"id":"gate","kind":"polygon","sides":4,"x":40,"y":80,"rotation":270,"strokeStyle":"Dashed","stroke":"#000000","shadow":{"blur":8}},{"id":"flow","kind":"arrow","x":300,"y":100,"width":120,"height":16,"rotation":-45},{"id":"note","kind":"text","text":"Note","fontWeight":"bold","textAlign":"center","x":300,"y":200}]}"##)
        #expect(doc.nodes.map(\.kind) == [.frame, .polygon, .arrow, .text])
        #expect(doc.nodes[1].sides == 4 && doc.nodes[1].rotation == -90 && doc.nodes[1].strokeStyle == .dashed)
        #expect(doc.nodes[1].shadow == DesignShadow(blur: 8))
        #expect(doc.nodes[2].stroke == .black && doc.nodes[2].strokeWidth == 2 && doc.nodes[2].rotation == -45)
        #expect(doc.nodes[3].fontWeight == .bold && doc.nodes[3].textAlign == .center)
        #expect(doc.children(of: doc.nodes[0].id).contains(doc.nodes[1].id))
        var locked = doc
        locked.setLocked(locked.nodes[1].id, true)
        let snapshot = try DesignTools.snapshot(locked)
        let result = try DesignTools.publish(["baseRevision": try #require(snapshot["baseRevision"]),
            "design": .string(String(decoding: try #require(snapshot["document"]).serialized(), as: UTF8.self))], replacing: locked)
        #expect(result == locked)
        let reference = try DesignTools.referencePrompt(doc, selection: [doc.nodes[1].id])
        #expect(reference.contains("rotation -90°") && reference.contains("dashed") && reference.contains("Shadow:"))
        // Referencing or exporting a frame brings what it holds.
        #expect(try DesignTools.referencePrompt(doc, selection: [doc.nodes[0].id]).contains(doc.nodes[1].id.uuidString))
        #expect(try DesignExportPlan(document: doc, selection: [doc.nodes[0].id]).nodes.count == 4)
    }

    @Test func descriptionsPersistAndOlderShapesRemainCompatible() throws {
        var doc = try publish(#"{"nodes":[{"id":"button","text":"Continue","description":"Continue only after the form is valid."}]}"#)
        let id = doc.nodes[0].id
        #expect(doc.nodes[0].text == "Continue")
        #expect(doc.nodes[0].description == "Continue only after the form is valid.")
        #expect(try JSONDecoder().decode(DesignDocument.self, from: JSONEncoder().encode(doc)) == doc)
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(doc.nodes[0])) as? [String: Any])
        encoded.removeValue(forKey: "description")
        let old = try JSONDecoder().decode(DesignNode.self, from: JSONSerialization.data(withJSONObject: encoded))
        #expect(old.description == nil)
        let copies = doc.duplicate([id])
        #expect(doc.node(try #require(copies.first))?.description == doc.node(id)?.description)
    }

    @Test func descriptionSurvivesAgentUpdatesUnlessExplicitlyCleared() throws {
        let original = try publish(#"{"nodes":[{"id":"card","description":"Show the latest order status."}]}"#)
        var object = try #require(DesignTools.snapshot(original)["document"]?.object)
        var nodes = try #require(object["nodes"]?.array)
        var node = try #require(nodes[0].object)
        node.removeValue(forKey: "description")
        node["text"] = "Order"
        nodes[0] = .object(node); object["nodes"] = .array(nodes)
        let updated = try publish(String(decoding: JSONValue.object(object).serialized(), as: UTF8.self), replacing: original)
        #expect(updated.nodes[0].description == original.nodes[0].description)
        node["description"] = ""
        nodes[0] = .object(node); object["nodes"] = .array(nodes)
        let cleared = try publish(String(decoding: JSONValue.object(object).serialized(), as: UTF8.self), replacing: updated)
        #expect(cleared.nodes[0].description == nil)
    }

    @Test func referencesCarrySelectedDescriptionsAndVisualProperties() throws {
        var doc = try publish(architecture)
        let first = doc.nodes[0].id, second = doc.nodes[1].id
        doc.update([first]) { $0.description = "Open the account settings when selected." }
        doc.update([second]) { $0.description = "Unselected server-only detail." }
        let reference = try DesignTools.referencePrompt(doc, selection: [first])
        #expect(reference.contains("Open the account settings when selected."))
        #expect(reference.contains(first.uuidString))
        #expect(reference.contains("width"))
        #expect(reference.contains("fill"))
        #expect(reference.contains("HTTPS"))
        #expect(!reference.contains("Unselected server-only detail."))
        doc.setHidden(second, true)
        let wholeCanvas = try DesignTools.referencePrompt(doc)
        #expect(!wholeCanvas.contains("Unselected server-only detail."))
    }

    @Test func descriptionEditsInvalidateOldAgentRevisions() throws {
        var doc = try publish(architecture)
        let revision = try DesignTools.revision(of: doc)
        let id = doc.nodes[0].id
        doc.update([id]) { $0.description = "Require confirmation before navigating away." }
        #expect(try DesignTools.revision(of: doc) != revision)
        #expect(throws: DesignToolError.self) {
            try DesignTools.publish(["design": .string(architecture), "baseRevision": .string(revision)], replacing: doc)
        }
    }

    @Test func descriptionsAreBoundedAndOversizedChatReferencesFailClearly() throws {
        let value: JSONValue = ["nodes": [["id": "large", "description": .string(String(repeating: "x", count: 8_001))]]]
        #expect(throws: DesignToolError.self) { try publish(String(decoding: value.serialized(), as: UTF8.self)) }
        var doc = DesignDocument()
        for index in 0..<5 {
            let id = doc.add(.rectangle, in: CGRect(x: index * 300, y: 0, width: 220, height: 100))
            doc.update([id]) { $0.description = String(repeating: "x", count: 8_001) }
        }
        #expect(doc.nodes.allSatisfy { $0.description?.count == 8_000 })
        #expect(throws: DesignToolError.self) { try DesignTools.referencePrompt(doc) }
    }

    @Test func refreshingTheSameSelectionReplacesOnlyItsPreviousReference() throws {
        var doc = try publish(architecture)
        let first = doc.nodes[0].id, second = doc.nodes[1].id
        doc.update([first]) { $0.description = "Old behavior" }
        let firstReference = try DesignTools.referencePrompt(doc, selection: [first])
        let secondReference = try DesignTools.referencePrompt(doc, selection: [second])
        var draft = DesignTools.mergingReference(firstReference, into: "Build this page.")
        draft = DesignTools.mergingReference(secondReference, into: draft)
        draft += "\nKeep my final note."
        doc.update([first]) { $0.description = "New behavior" }
        let updated = try DesignTools.referencePrompt(doc, selection: [first])
        draft = DesignTools.mergingReference(updated, into: draft)
        #expect(draft.hasPrefix("Build this page."))
        #expect(draft.hasSuffix("Keep my final note."))
        #expect(draft.contains(secondReference))
        #expect(draft.contains("New behavior"))
        #expect(!draft.contains("Old behavior"))
        #expect(draft.components(separatedBy: "<design_reference elements=").count == 3)
    }
}
