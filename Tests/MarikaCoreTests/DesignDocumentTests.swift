import Foundation
import Testing
@testable import MarikaCore

struct DesignDocumentTests {
    @Test func HitTestPicksTopmostAndSkipsLockedOrHidden() {
        var doc = DesignDocument()
        let back = doc.add(.rectangle, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        let front = doc.add(.rectangle, in: CGRect(x: 50, y: 50, width: 100, height: 100))
        #expect(doc.hitTest(CGPoint(x: 60, y: 60)) == front)
        doc.update([front]) { $0.isLocked = true }
        #expect(doc.hitTest(CGPoint(x: 60, y: 60)) == back)
        doc.update([back]) { $0.isHidden = true }
        #expect(doc.hitTest(CGPoint(x: 60, y: 60)) == nil)
    }

    @Test func EllipseCornersAreNotHit() {
        var doc = DesignDocument()
        _ = doc.add(.ellipse, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(doc.hitTest(CGPoint(x: 2, y: 2)) == nil)
        #expect(doc.hitTest(CGPoint(x: 50, y: 50)) != nil)
    }

    @Test func ResizeKeepsMinimumSizeAndOppositeEdge() {
        var doc = DesignDocument()
        let id = doc.add(.rectangle, in: CGRect(x: 10, y: 10, width: 100, height: 50))
        doc.resize(id, handle: .bottomRight, to: CGPoint(x: 0, y: 0))
        let node = doc.node(id)!
        #expect(node.x == 10); #expect(node.y == 10)
        #expect(node.width == DesignDocument.minimumSize); #expect(node.height == DesignDocument.minimumSize)
        doc.resize(id, handle: .topLeft, to: CGPoint(x: 0, y: 0))
        #expect(doc.node(id)!.frame.maxX == 18)
        #expect(doc.node(id)!.x == 0)
    }

    @Test func MoveSkipsLockedNodes() {
        var doc = DesignDocument()
        let a = doc.add(.rectangle, in: CGRect(x: 0, y: 0, width: 10, height: 10))
        let b = doc.add(.rectangle, in: CGRect(x: 0, y: 0, width: 10, height: 10))
        doc.update([b]) { $0.isLocked = true }
        doc.move([a, b], by: CGSize(width: 5, height: 7))
        #expect(doc.node(a)!.frame.origin == CGPoint(x: 5, y: 7))
        #expect(doc.node(b)!.frame.origin == .zero)
    }

    @Test func ReorderDuplicateAndAlign() {
        var doc = DesignDocument()
        let a = doc.add(.rectangle, in: CGRect(x: 0, y: 0, width: 10, height: 10))
        let b = doc.add(.rectangle, in: CGRect(x: 40, y: 0, width: 20, height: 10))
        doc.reorder([a], toFront: true)
        #expect(doc.nodes.last?.id == a)
        doc.align([a, b], .right)
        #expect(doc.node(a)!.frame.maxX == 60)
        let copies = doc.duplicate([a])
        #expect(copies.count == 1)
        #expect(copies[0] != a)
        #expect(doc.nodes.count == 3)
    }

    @Test func ProjectRoundTripsDesignAndOldProjectsDecode() throws {
        var project = Project(path: "/tmp/x")
        var doc = DesignDocument(); doc.add(.text, in: CGRect(x: 1, y: 2, width: 3, height: 4))
        project.design = doc
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(decoded.design == doc)
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as! [String: Any]
        old["design"] = nil
        #expect(try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: old)).design == nil)
    }
}
