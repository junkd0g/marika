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

    @Test func RotatedLayersHitResizeAndMeasureAlongTheirOwnAxes() {
        var doc = DesignDocument()
        let id = doc.add(.rectangle, in: CGRect(x: 0, y: 0, width: 200, height: 20))
        doc.update([id]) { $0.rotation = 90 }
        let node = doc.node(id)!
        #expect(abs(node.bounds.minX - 90) < 0.001 && abs(node.bounds.width - 20) < 0.001)
        #expect(abs(node.bounds.minY + 90) < 0.001 && abs(node.bounds.height - 200) < 0.001)
        #expect(doc.hitTest(CGPoint(x: 100, y: 80)) == id)
        #expect(doc.hitTest(CGPoint(x: 20, y: 10)) == nil)
        // The right edge now points down; dragging it lengthens the layer without moving the top.
        let longer = node.resized(.right, to: CGPoint(x: 100, y: 210))
        #expect(abs(longer.width - 300) < 0.001 && abs(longer.height - 20) < 0.001)
        #expect(abs(longer.bounds.minY + 90) < 0.001 && abs(longer.bounds.maxY - 210) < 0.001)
        doc.update([id]) { $0.rotation = 360 }
        #expect(doc.node(id)!.rotation == nil)
        doc.update([id]) { $0.rotation = 270 }
        #expect(doc.node(id)!.rotation == -90)
    }

    @Test func LinesFollowTheirEndpoints() {
        var doc = DesignDocument()
        let id = doc.addLine(.arrow, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 110))
        let line = doc.node(id)!
        #expect(line.width == 100 && line.rotation == 90 && line.stroke != nil)
        #expect(abs(line.endpoints.start.x - 10) < 0.001 && abs(line.endpoints.start.y - 10) < 0.001)
        #expect(abs(line.endpoints.end.x - 10) < 0.001 && abs(line.endpoints.end.y - 110) < 0.001)
        #expect(doc.hitTest(CGPoint(x: 12, y: 60)) == id)
        #expect(doc.hitTest(CGPoint(x: 40, y: 60)) == nil)
        #expect(doc.hitTest(CGPoint(x: 20, y: 60), slop: 4) == id)
    }

    @Test func PolygonsAndStarsFillTheirBoxAndOnlyHitInside() {
        let triangle = DesignNode.outline(.polygon, sides: nil, in: CGRect(x: 0, y: 0, width: 100, height: 80))
        #expect(triangle.count == 3)
        #expect(abs(triangle[0].x - 50) < 0.001 && abs(triangle[0].y) < 0.001)
        #expect(abs(triangle.map(\.y).max()! - 80) < 0.001 && abs(triangle.map(\.x).min()!) < 0.001)
        #expect(DesignNode.outline(.star, sides: 5, in: CGRect(x: 0, y: 0, width: 10, height: 10)).count == 10)
        var doc = DesignDocument()
        let id = doc.add(.polygon, in: CGRect(x: 0, y: 0, width: 100, height: 80))
        #expect(doc.hitTest(CGPoint(x: 50, y: 60)) == id)
        #expect(doc.hitTest(CGPoint(x: 4, y: 4)) == nil)
        doc.update([id]) { $0.sides = 40 }
        #expect(doc.node(id)!.sides == 12)
    }

    @Test func FramesCarryTheLayersInsideThem() {
        var doc = DesignDocument()
        let outside = doc.add(.rectangle, in: CGRect(x: 500, y: 0, width: 50, height: 50))
        let frame = doc.add(.frame, in: CGRect(x: 0, y: 0, width: 300, height: 200))
        let inside = doc.add(.rectangle, in: CGRect(x: 20, y: 20, width: 50, height: 50))
        let straddling = doc.add(.rectangle, in: CGRect(x: 280, y: 20, width: 50, height: 50))
        let locked = doc.add(.ellipse, in: CGRect(x: 100, y: 100, width: 40, height: 40))
        doc.setLocked(locked, true)
        #expect(doc.children(of: frame) == [inside, locked])
        #expect(doc.parents == [inside: frame, locked: frame])
        #expect(doc.carried(by: [frame]) == [frame, inside])
        #expect(doc.children(of: inside).isEmpty)
        let wrapper = doc.wrapInFrame([outside, straddling])!
        #expect(doc.node(wrapper)!.frame == CGRect(x: 280, y: 0, width: 270, height: 70))
        #expect(doc.nodes.first?.id == wrapper)
        #expect(doc.children(of: wrapper).isSuperset(of: [outside, straddling]))
        doc.setHidden(frame, true)
        #expect(doc.children(of: frame).isEmpty)
        let around = doc.add(.frame, in: CGRect(x: -10, y: -10, width: 1_000, height: 1_000))
        #expect(doc.nodes.first?.id == around)
        #expect(doc.children(of: around).contains(inside))
    }

    @Test func SnappingLinesUpEdgesAndReportsGuides() {
        let target = CGRect(x: 100, y: 100, width: 80, height: 40)
        let near = DesignSnap.move(CGRect(x: 183, y: 300, width: 50, height: 50), targets: [target], threshold: 5)
        #expect(near.offset == CGSize(width: -3, height: 0))
        #expect(near.guides == [DesignGuide(axis: .vertical, position: 180, start: 100, end: 350)])
        let far = DesignSnap.move(CGRect(x: 400, y: 300, width: 50, height: 50), targets: [target], threshold: 5)
        #expect(far.offset == .zero && far.guides.isEmpty)
        let centered = DesignSnap.move(CGRect(x: 117, y: 400, width: 50, height: 50), targets: [target], threshold: 5)
        #expect(centered.offset.width == -2)
        let locked = DesignSnap.move(CGRect(x: 183, y: 300, width: 50, height: 50), targets: [target], threshold: 5, x: false)
        #expect(locked.offset == .zero)
        let corner = DesignSnap.point(CGPoint(x: 178, y: 143), targets: [target], threshold: 5)
        #expect(corner.point == CGPoint(x: 180, y: 140) && corner.guides.count == 2)
    }

    @Test func LayerTreeNestsFramesAndCollapsesOnlyTheirDescendants() {
        var doc = DesignDocument()
        let outer = doc.add(.frame, in: CGRect(x: -100, y: -100, width: 500, height: 500))
        let inner = doc.add(.frame, in: CGRect(x: 0, y: 0, width: 200, height: 200))
        let child = doc.add(.rectangle, in: CGRect(x: 20, y: 20, width: 30, height: 30))
        let sibling = doc.add(.text, in: CGRect(x: 250, y: 20, width: 80, height: 30))
        let outside = doc.add(.ellipse, in: CGRect(x: 600, y: 20, width: 30, height: 30))
        let rows = doc.layerHierarchy()
        #expect(rows.map(\.id) == [outside, outer, sibling, inner, child])
        #expect(rows.map(\.depth) == [0, 0, 1, 1, 2])
        #expect(rows.first(where: { $0.id == child })?.parentID == inner)
        #expect(rows.first(where: { $0.id == outer })?.hasChildren == true)
        #expect(doc.layerHierarchy(collapsing: [inner]).map(\.id) == [outside, outer, sibling, inner])
        #expect(doc.layerHierarchy(collapsing: [outer]).map(\.id) == [outside, outer])
        #expect(doc.nodes.count == 5)
    }

    @Test func ReorderingLayerRowsCarriesFramesAndPreservesMembershipAndLocks() {
        var doc = DesignDocument()
        let outer = doc.add(.frame, in: CGRect(x: 0, y: 0, width: 500, height: 500))
        let inner = doc.add(.frame, in: CGRect(x: 20, y: 20, width: 200, height: 200))
        let child = doc.add(.rectangle, in: CGRect(x: 40, y: 40, width: 50, height: 50))
        let sibling = doc.add(.text, in: CGRect(x: 300, y: 20, width: 50, height: 50))
        let outside = doc.add(.ellipse, in: CGRect(x: 700, y: 0, width: 50, height: 50))
        let parents = doc.parents
        doc.reorderLayers([inner], before: sibling)
        #expect(doc.layerHierarchy().map(\.id) == [outside, outer, inner, child, sibling])
        #expect(doc.parents == parents)
        doc.reorderLayers([inner], before: nil)
        #expect(doc.layerHierarchy().map(\.id) == [outside, outer, sibling, inner, child])
        doc.reorder([inner], toFront: true)
        #expect(doc.layerHierarchy().map(\.id) == [outside, outer, inner, child, sibling])
        #expect(doc.parents == parents)
        doc.step(inner, forward: false)
        #expect(doc.layerHierarchy().map(\.id) == [outside, outer, sibling, inner, child])
        #expect(doc.parents == parents)
        let before = doc
        doc.reorderLayers([inner], before: outside)
        #expect(doc == before)
        doc.setLocked(child, true)
        let locked = doc
        doc.reorderLayers([inner], before: sibling)
        #expect(doc == locked)
    }

    @Test func HandlesKeepProportionsResizeFromCenterAndScaleGroups() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        #expect(DesignHandle.bottomRight.resize(rect, to: CGPoint(x: 300, y: 110), keepAspect: true) == CGRect(x: 0, y: 0, width: 300, height: 150))
        #expect(DesignHandle.right.resize(rect, to: CGPoint(x: 100, y: 0), keepAspect: true) == CGRect(x: 0, y: 25, width: 100, height: 50))
        #expect(DesignHandle.right.resize(rect, to: CGPoint(x: 220, y: 0), fromCenter: true) == CGRect(x: -20, y: 0, width: 240, height: 100))
        #expect(DesignHandle.topLeft.resize(rect, to: CGPoint(x: 500, y: 500)) == CGRect(x: 192, y: 92, width: 8, height: 8))
        var doc = DesignDocument()
        let a = doc.add(.rectangle, in: CGRect(x: 0, y: 0, width: 50, height: 50))
        let b = doc.add(.rectangle, in: CGRect(x: 150, y: 50, width: 50, height: 50))
        let box = doc.bounds(of: [a, b])!
        doc.apply([a: doc.node(a)!.scaled(from: box, to: CGRect(x: 0, y: 0, width: 400, height: 100)),
                   b: doc.node(b)!.scaled(from: box, to: CGRect(x: 0, y: 0, width: 400, height: 100))])
        #expect(doc.node(a)!.frame == CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(doc.node(b)!.frame == CGRect(x: 300, y: 50, width: 100, height: 50))
    }

    @Test func DistributeEvensGapsAndASingleLayerAlignsToItsFrame() {
        var doc = DesignDocument()
        let a = doc.add(.rectangle, in: CGRect(x: 0, y: 0, width: 20, height: 20))
        let b = doc.add(.rectangle, in: CGRect(x: 30, y: 0, width: 40, height: 20))
        let c = doc.add(.rectangle, in: CGRect(x: 180, y: 0, width: 20, height: 20))
        doc.distribute([a, b, c], .horizontal)
        #expect(doc.node(a)!.x == 0 && doc.node(b)!.x == 80 && doc.node(c)!.x == 180)
        doc.align([a], .centerX)
        #expect(doc.node(a)!.x == 0)
        doc.align([a], .centerX, within: CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(doc.node(a)!.x == 90)
    }

    @Test func ConnectionsCanBeDrawnFoundRelabeledAndRemoved() {
        var doc = DesignDocument()
        let a = doc.add(.rectangle, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        let b = doc.add(.rectangle, in: CGRect(x: 300, y: 0, width: 100, height: 100))
        let edge = doc.connect(a, b)!
        let again = doc.connect(a, b), toItself = doc.connect(a, a), toNothing = doc.connect(a, UUID())
        #expect(again == edge && toItself == nil && toNothing == nil)
        #expect(doc.connection(at: CGPoint(x: 200, y: 52), tolerance: 4) == edge)
        #expect(doc.connection(at: CGPoint(x: 200, y: 80), tolerance: 4) == nil)
        doc.updateConnection(edge) { $0.label = "HTTPS"; ($0.from, $0.to) = ($0.to, $0.from) }
        #expect(doc.connections == [DesignConnection(id: edge, from: b, to: a, label: "HTTPS")])
        doc.removeConnection(edge)
        doc.normalize()
        #expect(doc.connections == nil)
    }

    @Test func PastedLayersGetFreshIdentitiesAndKeepTheirConnections() throws {
        var doc = DesignDocument()
        let a = doc.add(.rectangle, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        let b = doc.add(.rectangle, in: CGRect(x: 200, y: 0, width: 100, height: 100))
        doc.connect(a, b)
        doc.setLocked(b, true)
        let clip = try JSONDecoder().decode(DesignClip.self, from: JSONEncoder().encode(doc.clip([a, b])))
        let pasted = doc.paste(clip, centeredAt: CGPoint(x: 1_000, y: 1_000))
        #expect(pasted.count == 2 && Set(pasted).isDisjoint(with: [a, b]))
        #expect(doc.bounds(of: Set(pasted)) == CGRect(x: 850, y: 950, width: 300, height: 100))
        #expect(doc.connections?.count == 2)
        #expect(doc.node(pasted[1])?.isLocked == false)
        #expect(doc.node(pasted[0])?.name == doc.node(a)?.name)
    }

    @Test func NewAppearanceFieldsNormalizeAndStayOutOfOlderDocuments() throws {
        var doc = DesignDocument()
        let id = doc.add(.rectangle, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(doc.nodes[0])) as! [String: Any]
        #expect(Set(["rotation", "sides", "fontWeight", "textAlign", "strokeStyle", "shadow"]).isDisjoint(with: plain.keys))
        doc.update([id]) {
            $0.strokeStyle = .solid; $0.sides = 5; $0.rotation = .nan
            $0.shadow = DesignShadow(color: DesignColor(2, 0, 0), x: .infinity, y: 2, blur: -4)
        }
        let node = doc.node(id)!
        #expect(node.strokeStyle == nil && node.sides == nil && node.rotation == nil)
        #expect(node.shadow == DesignShadow(color: DesignColor(1, 0, 0), x: 0, y: 2, blur: 0))
        #expect(node.visualBounds == CGRect(x: 0, y: 0, width: 100, height: 102))
        #expect(DesignColor(hex: "#3F80FF")?.hex == "#3F80FF")
        #expect(DesignColor(hex: "fff") == .white)
        #expect(DesignColor(hex: "00000080")?.hex == "#00000080")
        #expect(DesignColor(hex: "+12345") == nil && DesignColor(hex: "red") == nil)
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
