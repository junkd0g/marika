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
        #"{"nodes":[{"id":"a","fill":{"red":2,"green":0,"blue":0,"alpha":1}}]}"#
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
}
