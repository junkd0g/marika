import AppKit
import MarikaCore
import Observation
import UniformTypeIdentifiers

enum DesignTool: String, CaseIterable {
    case select = "Move", hand = "Hand", frame = "Frame", rectangle = "Rectangle", ellipse = "Ellipse"
    case polygon = "Polygon", star = "Star", line = "Line", arrow = "Arrow", text = "Text", connector = "Connector"

    static let shapes: [DesignTool] = [.rectangle, .ellipse, .polygon, .star, .line, .arrow]

    var kind: DesignNode.Kind? {
        switch self {
        case .frame: .frame
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .polygon: .polygon
        case .star: .star
        case .line: .line
        case .arrow: .arrow
        case .text: .text
        case .select, .hand, .connector: nil
        }
    }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .hand: "hand.raised"
        case .connector: "point.topleft.down.to.point.bottomright.curvepath"
        default: kind?.symbol ?? "questionmark"
        }
    }
    var shortcut: String {
        switch self {
        case .select: "V"; case .hand: "H"; case .frame: "F"; case .rectangle: "R"; case .ellipse: "O"
        case .line: "L"; case .arrow: "⇧L"; case .text: "T"; case .connector: "C"; case .polygon, .star: ""
        }
    }
    var help: String { shortcut.isEmpty ? rawValue : "\(rawValue) (\(shortcut))" }
}

struct DesignPointer {
    var location: CGPoint
    var modifiers: NSEvent.ModifierFlags = []
    var clicks = 1
    var shift: Bool { modifiers.contains(.shift) }
    var option: Bool { modifiers.contains(.option) }
    var command: Bool { modifiers.contains(.command) }
}

/// Selection, viewport and pointer interaction for one project's canvas. It outlives the view, so
/// zoom and selection survive switching tabs, and scripted checks can drive it without a window.
@MainActor @Observable
final class DesignCanvasModel {
    enum Draft: Equatable {
        case shape(DesignNode.Kind, CGRect)
        case line(DesignNode.Kind, CGPoint, CGPoint)
        case connector(from: UUID, to: CGPoint, target: UUID?)
    }
    enum Grip: Equatable { case resize(DesignHandle), rotate, endpoint(Int) }

    private struct Move {
        var start: CGPoint
        var origin: CGPoint
        var hit: UUID
        var collapses: Bool
        var originals: [UUID: DesignNode] = [:]
        var box = CGRect.zero
        var targets: [CGRect] = []
        var started = false
    }
    private struct Resize {
        var handle: DesignHandle
        var originals: [UUID: DesignNode]
        var box: CGRect
        /// A single rotated layer resizes along its own axes instead of the selection box.
        var rotated: DesignNode?
        var targets: [CGRect]
    }
    private enum Drag {
        case move(Move), resize(Resize)
        case rotate(DesignNode, start: Double)
        case endpoint(DesignNode, index: Int, targets: [CGRect])
        case create(DesignNode.Kind, start: CGPoint, origin: CGPoint, targets: [CGRect])
        case connect(from: UUID)
        case connectionLabel(UUID)
        case marquee(start: CGPoint, base: Set<UUID>, containers: Set<UUID>)
        case pan(offset: CGSize, origin: CGPoint)
    }

    static let pasteboardType = NSPasteboard.PasteboardType("app.marika.design-layers")
    static let labelFont = NSFont.systemFont(ofSize: 11)

    let editor: DesignWorkspace
    let projectID: UUID
    @ObservationIgnored weak var app: AppModel?

    var tool = DesignTool.select
    var lastShape = DesignTool.rectangle
    var selection: Set<UUID> = []
    var selectedConnection: UUID?
    var zoom = 1.0
    var offset = CGSize(width: 240, height: 120)
    var canvasSize = CGSize.zero
    var hovered: UUID?
    var guides: [DesignGuide] = []
    /// Marquee rectangle in canvas coordinates.
    var marquee: CGRect?
    var draft: Draft?
    var editingText: UUID?
    var renaming: UUID?
    var collapsedFrames: Set<UUID> = []
    var showsTemplates = false
    var showsHistory = false
    var showsHealth = false
    let health = DesignHealthModel()
    var ticketDraft: DesignTicketDraft?
    var isPanning = false
    var spaceDown = false
    /// Bumped to hand keyboard focus back to the canvas, for example after editing text.
    var focusRequests = 0
    var errorTitle = ""
    var errorMessage: String?
    var preparingReference = false

    @ObservationIgnored var automaticallyFits = true
    @ObservationIgnored private var drag: Drag?
    @ObservationIgnored private var ignoreDragUntilEnd = false
    @ObservationIgnored private var editingIsNew = false
    @ObservationIgnored private var editingAutoSizes = false
    @ObservationIgnored private var layerSelectionAnchor: UUID?

    init(editor: DesignWorkspace, projectID: UUID, app: AppModel? = nil) {
        self.editor = editor; self.projectID = projectID; self.app = app
    }

    // MARK: Derived state

    var doc: DesignDocument { editor.document }
    var selectedNodes: [DesignNode] { doc.nodes.filter { selection.contains($0.id) } }
    var layerRows: [DesignLayerEntry] { doc.layerHierarchy(collapsing: collapsedFrames) }

    /// Row gestures coexist with disclosure/rename controls, so select explicitly instead of
    /// relying on List's mouse handling through the row's SwiftUI gesture recognizers.
    func selectLayer(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        guard doc.node(id) != nil else { return }
        selectedConnection = nil
        let rows = layerRows.map(\.id)
        let anchor = layerSelectionAnchor.flatMap { selection.contains($0) ? $0 : nil }
            ?? rows.first(where: { selection.contains($0) })
        if modifiers.contains(.shift), let anchor,
           let start = rows.firstIndex(of: anchor), let end = rows.firstIndex(of: id) {
            let range = Set(rows[min(start, end)...max(start, end)])
            selection = modifiers.contains(.command) ? selection.union(range) : range
        } else {
            if modifiers.contains(.command) {
                if !selection.insert(id).inserted { selection.remove(id) }
            } else { selection = [id] }
            layerSelectionAnchor = id
        }
    }

    func revealSelectedLayers() {
        let parents = doc.parents
        for id in selection {
            var parent = parents[id]
            while let value = parent { collapsedFrames.remove(value); parent = parents[value] }
        }
    }

    func moveLayerRows(from source: IndexSet, to destination: Int) {
        let rows = layerRows
        let ids = Set(source.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
        guard let first = rows.first(where: { ids.contains($0.id) }) else { return }
        // The flat row index includes descendants. Find the next sibling at the drop position.
        let target = rows.dropFirst(destination).first { $0.parentID == first.parentID && !ids.contains($0.id) }?.id
        edit { $0.reorderLayers(ids, before: target) }
    }
    var editableSelection: Set<UUID> { selection.intersection(doc.editableIDs) }
    var activeConnection: DesignConnection? {
        guard selection.isEmpty, let id = selectedConnection else { return nil }
        return doc.connections?.first { $0.id == id }
    }
    var linkedTickets: [SpaceTicket] { app?.designTickets(projectID: projectID, elements: doc.withChildren(selection)) ?? [] }
    var implementationBadges: [(node: UUID, ticket: UUID, label: String, status: SpaceTicket.Status, rect: CGRect)] {
        doc.nodes.filter { !$0.isHidden }.compactMap { node in
            guard let ticket = app?.designTickets(projectID: projectID, elements: [node.id]).first else { return nil }
            let box = toScreen(node.bounds)
            guard box.width >= 24, box.height >= 24 else { return nil }
            let full = box.height >= 64 && box.width >= 140
            let width = full ? min(145.0, box.width - 8) : 12.0
            let label = full ? String(ticket.key.prefix(12)) + " · " + ticket.status.rawValue : ""
            return (node.id, ticket.id, label, ticket.status,
                    CGRect(x: box.maxX - width - 4, y: box.minY + 4, width: width, height: full ? 18 : 12))
        }
    }
    func prepareTicket() {
        do { ticketDraft = try DesignTicketDraft(projectID: projectID, document: doc, selection: doc.withChildren(selection)) }
        catch { errorTitle = "Create ticket"; errorMessage = error.localizedDescription }
    }
    func tidy(_ direction: DesignLayoutDirection) {
        edit { $0.tidyLayout(selection: selection, direction: direction) }; fit()
    }
    var isDragging: Bool { drag != nil }

    func toDoc(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.width) / zoom, y: (point.y - offset.height) / zoom)
    }
    func toScreen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * zoom + offset.width, y: point.y * zoom + offset.height)
    }
    func toScreen(_ rect: CGRect) -> CGRect {
        CGRect(origin: toScreen(rect.origin), size: CGSize(width: rect.width * zoom, height: rect.height * zoom))
    }

    /// Unlocked, visible layers that resize handles act on.
    private var handled: [DesignNode] { selectedNodes.filter { !$0.isLocked && !$0.isHidden } }
    /// The one selected layer, which shows handles on its own, possibly rotated, box.
    var soleNode: DesignNode? { selection.count == 1 ? handled.first : nil }
    /// The shared box around several selected layers.
    var groupBox: CGRect? { handled.count > 1 ? doc.bounds(of: Set(handled.map(\.id))) : nil }

    /// Titles above frames, in screen coordinates. A frame that holds layers is picked up by its title.
    var frameLabels: [(id: UUID, name: String, rect: CGRect)] {
        doc.nodes.compactMap { node -> (id: UUID, name: String, rect: CGRect)? in
            guard node.kind == .frame, !node.isHidden, node.width * zoom >= 28 else { return nil }
            let corner = toScreen(node.bounds.origin)
            let width = (node.name as NSString).size(withAttributes: [.font: Self.labelFont]).width + 2
            return (node.id, node.name, CGRect(x: corner.x, y: corner.y - 18, width: min(width, node.bounds.width * zoom), height: 16))
        }
    }

    /// The knob above a selected layer that rotates it, in screen coordinates.
    var rotationKnob: CGPoint? {
        guard editingText == nil, let node = soleNode, !node.isLinear, node.width * zoom >= 28 else { return nil }
        let top = toScreen(node.toWorld(CGPoint(x: node.frame.midX, y: node.frame.minY)))
        return CGPoint(x: top.x + sin(node.radians) * 22, y: top.y - cos(node.radians) * 22)
    }

    /// Topmost layer under a screen point. Frames holding other layers answer only to their title.
    func nodeHit(at location: CGPoint) -> UUID? {
        if let label = frameLabels.last(where: { $0.rect.contains(location) }), doc.node(label.id)?.isLocked == false { return label.id }
        return doc.hitTest(toDoc(location), slop: 3 / zoom, skipping: Set(doc.parents.values))
    }

    func grip(at location: CGPoint) -> Grip? {
        guard tool == .select, editingText == nil else { return nil }
        let reach = 7 / zoom
        if let node = soleNode {
            if node.isLinear {
                let ends = [node.endpoints.start, node.endpoints.end].map(toScreen)
                return ends.firstIndex { hypot($0.x - location.x, $0.y - location.y) <= 8 }.map { Grip.endpoint($0) }
            }
            if let knob = rotationKnob, hypot(knob.x - location.x, knob.y - location.y) <= 9 { return .rotate }
            return handle(near: node.toLocal(toDoc(location)), of: node.frame, reach: reach).map { Grip.resize($0) }
        }
        return groupBox.flatMap { handle(near: toDoc(location), of: $0, reach: reach) }.map { Grip.resize($0) }
    }

    /// Corners win over edges; the inside of a small layer stays free for moving it.
    private func handle(near point: CGPoint, of rect: CGRect, reach: Double) -> DesignHandle? {
        let inner = min(reach, Double(min(rect.width, rect.height)) / 4)
        guard rect.insetBy(dx: -reach, dy: -reach).contains(point), !rect.insetBy(dx: inner, dy: inner).contains(point) else { return nil }
        let corners: [DesignHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
        if let corner = corners.first(where: { handle in
            let spot = handle.point(in: rect)
            return Double(abs(spot.x - point.x)) <= reach && Double(abs(spot.y - point.y)) <= reach
        }) { return corner }
        let distances: [(DesignHandle, CGFloat)] = [(.left, abs(point.x - rect.minX)), (.right, abs(point.x - rect.maxX)),
                                                   (.top, abs(point.y - rect.minY)), (.bottom, abs(point.y - rect.maxY))]
        return distances.min { $0.1 < $1.1 }?.0
    }

    // MARK: Pointer

    func pointerDown(_ pointer: DesignPointer, panning: Bool = false) {
        if editingText != nil { commitText() }
        renaming = nil
        ignoreDragUntilEnd = false
        let point = toDoc(pointer.location)
        if panning || spaceDown || tool == .hand {
            automaticallyFits = false; isPanning = true
            drag = .pan(offset: offset, origin: pointer.location)
            return
        }
        if tool == .select, let badge = implementationBadges.last(where: { $0.rect.contains(pointer.location) }) {
            app?.openTicket(badge.ticket); return
        }
        if tool == .select, let edge = (doc.connections ?? []).last(where: { edge in
            guard !edge.label.isEmpty, let center = edge.labelPoint(in: doc.nodes) else { return false }
            let spot = toScreen(center), width = max(30, Double(edge.label.count) * 6 * zoom + 12)
            return CGRect(x: spot.x - width / 2, y: spot.y - 12, width: width, height: 24).contains(pointer.location)
        }) {
            selection = []; selectedConnection = edge.id; editor.beginInteraction(); drag = .connectionLabel(edge.id); return
        }
        if tool == .connector {
            guard let source = nodeHit(at: pointer.location) else { return }
            drag = .connect(from: source)
            draft = .connector(from: source, to: point, target: nil)
            return
        }
        if let kind = tool.kind {
            let targets = doc.snapTargets(excluding: [])
            editor.beginInteraction()
            drag = .create(kind, start: snapped(point, targets: targets, bypass: pointer.command), origin: pointer.location, targets: targets)
            return
        }
        if let grip = grip(at: pointer.location) { begin(grip, at: point); return }
        if let hit = nodeHit(at: pointer.location) {
            if pointer.clicks >= 2, doc.node(hit)?.isLinear == false { selection = [hit]; beginEditing(hit); return }
            selectedConnection = nil
            var collapses = false
            if pointer.shift {
                if selection.contains(hit) { selection.remove(hit); return }
                selection.insert(hit)
            } else if selection.contains(hit) {
                collapses = selection.count > 1
            } else {
                selection = [hit]
            }
            editor.beginInteraction()
            drag = .move(Move(start: point, origin: pointer.location, hit: hit, collapses: collapses))
            return
        }
        if let edge = doc.connection(at: point, tolerance: 5 / zoom) {
            selection = []; selectedConnection = edge
            return
        }
        selectedConnection = nil
        drag = .marquee(start: point, base: pointer.shift ? selection : [], containers: Set(doc.parents.values))
        if !pointer.shift { selection = [] }
    }

    private func begin(_ grip: Grip, at point: CGPoint) {
        editor.beginInteraction()
        let ids = Set(handled.map(\.id))
        let targets = doc.snapTargets(excluding: ids)
        switch grip {
        case .rotate:
            guard let node = soleNode else { return }
            drag = .rotate(node, start: Double(atan2(point.y - node.center.y, point.x - node.center.x)))
        case .endpoint(let index):
            guard let node = soleNode else { return }
            drag = .endpoint(node, index: index, targets: targets)
        case .resize(let handle):
            let originals = Dictionary(uniqueKeysWithValues: handled.map { ($0.id, $0) })
            let rotated = soleNode.flatMap { $0.rotation == nil ? nil : $0 }
            drag = .resize(Resize(handle: handle, originals: originals, box: doc.bounds(of: ids) ?? .zero, rotated: rotated, targets: targets))
        }
    }

    func pointerDragged(_ pointer: DesignPointer) {
        guard !ignoreDragUntilEnd, let drag else { return }
        let point = toDoc(pointer.location)
        switch drag {
        case .connectionLabel(let id):
            guard let edge = doc.connections?.first(where: { $0.id == id }), let route = edge.route(in: doc.nodes) else { return }
            editor.updateInteraction { $0.updateConnection(id) { $0.labelPosition = DesignConnection.fraction(on: route, nearest: point) } }
        case .move(var move):
            if !move.started {
                guard hypot(pointer.location.x - move.origin.x, pointer.location.y - move.origin.y) > 3 else { return }
                var ids = doc.carried(by: selection)
                if pointer.option {
                    // Copies keep document order, so they pair up with the layers they came from.
                    let sources = doc.nodes.filter { ids.contains($0.id) }.map(\.id)
                    var copies: [UUID] = []
                    editor.updateInteraction { copies = $0.duplicate(ids, offset: 0) }
                    selection = Set(zip(sources, copies).filter { selection.contains($0.0) }.map(\.1))
                    ids = Set(copies)
                }
                move.originals = Dictionary(uniqueKeysWithValues: doc.nodes.filter { ids.contains($0.id) }.map { ($0.id, $0) })
                move.box = doc.bounds(of: ids) ?? .zero
                move.targets = doc.snapTargets(excluding: ids)
                move.started = true
            }
            var dx = Double(point.x - move.start.x), dy = Double(point.y - move.start.y)
            var freeX = true, freeY = true
            if pointer.shift { if abs(dx) >= abs(dy) { dy = 0; freeY = false } else { dx = 0; freeX = false } }
            guides = []
            if !pointer.command {
                let snap = DesignSnap.move(move.box.offsetBy(dx: dx, dy: dy), targets: move.targets, threshold: 6 / zoom, x: freeX, y: freeY)
                guides = snap.guides
                // Land on whole pixels unless a guide placed the edge.
                let minX = Double(move.box.minX), minY = Double(move.box.minY)
                let snapX = Double(snap.offset.width), snapY = Double(snap.offset.height)
                dx = snapX != 0 ? dx + snapX : freeX ? (minX + dx).rounded() - minX : 0
                dy = snapY != 0 ? dy + snapY : freeY ? (minY + dy).rounded() - minY : 0
            }
            editor.updateInteraction { $0.apply(move.originals.mapValues { var node = $0; node.x += dx; node.y += dy; return node }) }
            self.drag = .move(move)
        case .resize(let resize):
            if let node = resize.rotated {
                guides = []
                editor.updateInteraction {
                    $0.apply([node.id: node.resized(resize.handle, to: point, keepAspect: pointer.shift, fromCenter: pointer.option)])
                }
            } else {
                let target = snapped(point, targets: resize.targets, bypass: pointer.command || pointer.shift,
                                     x: resize.handle.horizontal != 0, y: resize.handle.vertical != 0)
                let box = resize.handle.resize(resize.box, to: target, keepAspect: pointer.shift, fromCenter: pointer.option)
                editor.updateInteraction { $0.apply(resize.originals.mapValues { $0.scaled(from: resize.box, to: box) }) }
            }
        case .rotate(let node, let start):
            let angle = Double(atan2(point.y - node.center.y, point.x - node.center.x))
            var degrees = (node.rotation ?? 0) + (angle - start) * 180 / .pi
            degrees = pointer.shift ? (degrees / 15).rounded() * 15 : degrees.rounded()
            editor.updateInteraction { $0.apply([node.id: { var copy = node; copy.rotation = degrees; return copy }()]) }
        case .endpoint(let node, let index, let targets):
            let fixed = index == 0 ? node.endpoints.end : node.endpoints.start
            let end = pointer.shift ? constrained(point, around: fixed) : snapped(point, targets: targets, bypass: pointer.command)
            if pointer.shift { guides = [] }
            var copy = node
            if index == 0 { copy.setEndpoints(end, fixed) } else { copy.setEndpoints(fixed, end) }
            editor.updateInteraction { $0.apply([node.id: copy]) }
        case .create(let kind, let start, _, let targets):
            if kind == .line || kind == .arrow {
                if pointer.shift { guides = [] }
                draft = .line(kind, start, pointer.shift ? constrained(point, around: start) : snapped(point, targets: targets, bypass: pointer.command))
            } else {
                let corner = snapped(point, targets: targets, bypass: pointer.command || pointer.shift)
                draft = .shape(kind, creationRect(from: start, to: corner, square: pointer.shift, centered: pointer.option))
            }
        case .connect(let source):
            let target = nodeHit(at: pointer.location).flatMap { $0 == source ? nil : $0 }
            draft = .connector(from: source, to: point, target: target)
        case .marquee(let start, let base, let containers):
            let area = rect(start, point)
            marquee = area
            // A frame that holds layers joins only when the marquee surrounds it, so its contents can be picked.
            let hits = doc.nodes(in: area).filter { id in !containers.contains(id) || doc.node(id).map { area.contains($0.bounds) } == true }
            selection = base.union(hits)
        case .pan(let start, let origin):
            offset = CGSize(width: start.width + pointer.location.x - origin.x, height: start.height + pointer.location.y - origin.y)
        }
    }

    func pointerUp(_ pointer: DesignPointer) {
        defer { drag = nil; marquee = nil; draft = nil; guides = []; isPanning = false; editor.endInteraction() }
        if ignoreDragUntilEnd { ignoreDragUntilEnd = false; return }
        switch drag {
        case .move(let move) where !move.started && move.collapses && !pointer.shift:
            selection = [move.hit]
        case .create(let kind, let start, let origin, _):
            let clicked = hypot(pointer.location.x - origin.x, pointer.location.y - origin.y) < 4
            var created: UUID?
            editor.updateInteraction { doc in
                switch (clicked, draft) {
                case (false, .line(_, let from, let to)?): created = doc.addLine(kind, from: from, to: to)
                case (false, .shape(_, let area)?): created = doc.add(kind, in: area)
                default:
                    if kind == .line || kind == .arrow {
                        created = doc.addLine(kind, from: start, to: CGPoint(x: start.x + 120, y: start.y))
                    } else {
                        let size = kind == .frame ? CGSize(width: 320, height: 200) : CGSize(width: 100, height: 100)
                        created = doc.add(kind, in: CGRect(origin: start, size: size))
                    }
                }
                guard kind == .text, let created else { return }
                doc.update([created]) { node in
                    node.text = ""
                    if clicked { node.width = DesignDocument.minimumSize; node.height = ceil(DesignText.size(of: " ", in: node, width: nil).height) }
                }
            }
            tool = .select
            guard let created else { return }
            selection = [created]; selectedConnection = nil
            if kind == .text { beginEditing(created, isNew: true, autoSizes: clicked) }
        case .connect(let source):
            guard case .connector(_, _, let target?) = draft else { return }
            var created: UUID?
            editor.edit { created = $0.connect(source, target) }
            selection = []; selectedConnection = created
            tool = .select
        default: break
        }
    }

    /// Updates the hover highlight and returns the cursor for what is under the pointer.
    func pointerMoved(_ pointer: DesignPointer) -> NSCursor {
        if drag == nil {
            let next = tool == .connector || (tool == .select && !spaceDown && grip(at: pointer.location) == nil) ? nodeHit(at: pointer.location) : nil
            if next != hovered { hovered = next }
        }
        return cursor(at: pointer.location)
    }

    func cursor(at location: CGPoint) -> NSCursor {
        if isPanning { return .closedHand }
        if spaceDown || tool == .hand { return .openHand }
        if tool == .text { return .iBeam }
        if tool != .select { return .crosshair }
        switch grip(at: location) {
        case .resize(let handle):
            // Handles run clockwise in eighths of a turn, so rotation shifts which cursor fits.
            let all = DesignHandle.allCases
            let turned = (all.firstIndex(of: handle)! + Int(((soleNode?.rotation ?? 0) / 45).rounded()) + 16) % 8
            let position: NSCursor.FrameResizePosition = switch all[turned] {
            case .topLeft: .topLeft
            case .top: .top
            case .topRight: .topRight
            case .right: .right
            case .bottomRight: .bottomRight
            case .bottom: .bottom
            case .bottomLeft: .bottomLeft
            case .left: .left
            }
            return .frameResize(position: position, directions: .all)
        case .rotate, .endpoint: return .crosshair
        case nil: return .arrow
        }
    }

    private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func creationRect(from start: CGPoint, to point: CGPoint, square: Bool, centered: Bool) -> CGRect {
        var dx = point.x - start.x, dy = point.y - start.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side; dy = dy < 0 ? -side : side
        }
        return rect(centered ? CGPoint(x: start.x - dx, y: start.y - dy) : start, CGPoint(x: start.x + dx, y: start.y + dy))
    }

    /// Holds a dragged end to eighths of a turn around `origin`.
    private func constrained(_ point: CGPoint, around origin: CGPoint) -> CGPoint {
        let length = hypot(point.x - origin.x, point.y - origin.y)
        let angle = (atan2(point.y - origin.y, point.x - origin.x) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: (origin.x + length * cos(angle)).rounded(), y: (origin.y + length * sin(angle)).rounded())
    }

    /// Snaps a dragged point to nearby layers and shows the guides; otherwise lands on a whole pixel.
    private func snapped(_ point: CGPoint, targets: [CGRect], bypass: Bool, x: Bool = true, y: Bool = true) -> CGPoint {
        guides = []
        guard !bypass else { return CGPoint(x: point.x.rounded(), y: point.y.rounded()) }
        let snap = DesignSnap.point(point, targets: targets, threshold: 6 / zoom, x: x, y: y)
        guides = snap.guides
        return CGPoint(x: snap.point.x == point.x ? point.x.rounded() : snap.point.x,
                       y: snap.point.y == point.y ? point.y.rounded() : snap.point.y)
    }

    // MARK: Viewport

    func resize(to size: CGSize) {
        canvasSize = size
        if automaticallyFits { fit() }
    }

    /// Centers the visible canvas, or `target`, above the floating toolbar.
    func fit(to target: CGRect? = nil) {
        if target == nil { automaticallyFits = true }
        guard let box = target ?? doc.visibleBounds, box.width > 0, box.height > 0,
              canvasSize.width > 0, canvasSize.height > 0 else { return }
        let availableHeight = max(1, canvasSize.height - 132)
        zoom = min(2, max(0.0001, min(max(1, canvasSize.width - 64) / box.width, availableHeight / box.height)))
        offset = CGSize(width: (canvasSize.width - box.width * zoom) / 2 - box.minX * zoom,
                        height: 52 + (availableHeight - box.height * zoom) / 2 - box.minY * zoom)
    }

    func fitSelection() {
        guard let box = doc.bounds(of: selection) else { return }
        automaticallyFits = false
        fit(to: box)
    }

    func setZoom(_ value: Double, anchor: CGPoint? = nil) {
        guard value.isFinite else { return }
        automaticallyFits = false
        let anchor = anchor ?? CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let point = toDoc(anchor)
        // A canvas fitted below the usual floor can still zoom back in from there.
        zoom = min(32, max(min(zoom, 0.02), value))
        offset = CGSize(width: anchor.x - point.x * zoom, height: anchor.y - point.y * zoom)
    }

    func scroll(dx: Double, dy: Double, at location: CGPoint, zooming: Bool) {
        if zooming { setZoom(zoom * exp(dy * 0.01), anchor: location); return }
        automaticallyFits = false
        offset.width += dx; offset.height += dy
    }

    var zoomLabel: String { zoom < 0.01 ? "<1%" : "\(Int((zoom * 100).rounded()))%" }

    /// An agent or another window replaced the canvas while this one may be mid-drag.
    func externalChange() {
        ignoreDragUntilEnd = drag != nil
        drag = nil; marquee = nil; draft = nil; guides = []; isPanning = false; editingText = nil
        prune()
        fit()
    }

    func prune() {
        let existing = Set(doc.nodes.map(\.id))
        collapsedFrames.formIntersection(existing)
        if !selection.isSubset(of: existing) { selection.formIntersection(existing) }
        if let id = selectedConnection, doc.connections?.contains(where: { $0.id == id }) != true { selectedConnection = nil }
        if let id = editingText, !existing.contains(id) { editingText = nil }
        if let id = hovered, !existing.contains(id) { hovered = nil }
        if let id = renaming, !existing.contains(id) { renaming = nil }
    }

    // MARK: Keyboard

    /// Keys pressed without ⌘ while the canvas has focus. Returns false to pass the key on.
    func handleKey(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard !modifiers.contains(.command), !modifiers.contains(.control) else { return false }
        let shift = modifiers.contains(.shift), step = shift ? 10.0 : 1.0
        switch keyCode {
        case 53:
            if tool != .select { tool = .select } else { selection = []; selectedConnection = nil }
        case 51, 117: deleteSelection()
        case 123: nudge(-step, 0)
        case 124: nudge(step, 0)
        case 125: nudge(0, step)
        case 126: nudge(0, -step)
        case 36, 76:
            guard let node = soleNode, !node.isLinear else { return false }
            beginEditing(node.id)
        case 49: spaceDown = true
        case 18 where shift: fit()
        case 19 where shift: fitSelection()
        case 29 where shift: setZoom(1)
        default:
            guard !modifiers.contains(.option) else { return false }
            switch characters.lowercased() {
            case "v": tool = .select
            case "h": tool = .hand
            case "f": tool = .frame
            case "r": choose(.rectangle)
            case "o": choose(.ellipse)
            case "l": choose(shift ? .arrow : .line)
            case "t": tool = .text
            case "c": tool = .connector
            case "]": reorder(toFront: true)
            case "[": reorder(toFront: false)
            case "+", "=": setZoom(zoom * 1.25)
            case "-": setZoom(zoom / 1.25)
            default: return false
            }
        }
        return true
    }

    /// ⌘ shortcuts, handled before the menu bar while the canvas has focus.
    func handleCommand(_ characters: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        let shift = modifiers.contains(.shift), option = modifiers.contains(.option)
        switch (characters.lowercased(), shift, option) {
        case ("z", false, false): editor.undo(); prune()
        case ("z", true, false): editor.redo(); prune()
        case ("c", false, false): copySelection()
        case ("c", true, false): copyImage()
        case ("x", false, false): if copySelection() { deleteSelection() }
        case ("v", false, false): paste()
        case ("d", false, false): duplicateSelection()
        case ("a", false, false): selectAll()
        case ("]", false, false): step(forward: true)
        case ("[", false, false): step(forward: false)
        case ("g", false, true): frameSelection()
        case ("g", true, false): ungroup()
        case ("=", _, false), ("+", _, false): setZoom(zoom * 1.25)
        case ("-", false, false): setZoom(zoom / 1.25)
        default: return false
        }
        return true
    }

    func choose(_ shape: DesignTool) {
        tool = shape
        if DesignTool.shapes.contains(shape) { lastShape = shape }
    }

    func insertComponent(_ component: DesignComponent, at location: CGPoint? = nil) {
        if editingText != nil { commitText() }
        var center = location.map(toDoc) ?? toDoc(CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
        if location == nil {
            // Keep successive insertions separate without moving the user's existing artwork.
            for _ in 0..<24 {
                let box = component.makeNode(centeredAt: center).frame.insetBy(dx: -12, dy: -12)
                if !doc.nodes.contains(where: { !$0.isHidden && $0.kind != .frame && $0.bounds.intersects(box) }) { break }
                center.x += 32; center.y += 24
            }
        }
        var id: UUID?
        edit { id = $0.addComponent(component, centeredAt: center) }
        selection = Set(id.map { [$0] } ?? [])
        selectedConnection = nil
        tool = .select
        if location == nil, let id, let node = doc.node(id),
           !CGRect(origin: .zero, size: canvasSize).contains(toScreen(node.frame)) { fitSelection() }
        focusRequests += 1
    }

    @discardableResult
    func acceptComponentDrop(_ values: [String], at point: CGPoint) -> Bool {
        let components = values.compactMap { value -> DesignComponent? in
            guard value.hasPrefix(DesignComponentLibrary.dragPrefix) else { return nil }
            return DesignComponent(rawValue: String(value.dropFirst(DesignComponentLibrary.dragPrefix.count)))
        }
        for (index, component) in components.enumerated() {
            insertComponent(component, at: CGPoint(x: point.x + Double(index) * 24, y: point.y + Double(index) * 24))
        }
        return !components.isEmpty
    }

    // MARK: Editing

    func edit(coalescing key: String? = nil, _ change: (inout DesignDocument) -> Void) {
        editor.edit(coalescing: key, change)
    }

    /// Applies an inspector change to every selected layer as one undo step per property.
    func update(_ key: String, _ change: (inout DesignNode) -> Void) {
        let ids = selection
        edit(coalescing: "property:\(key):\(ids.hashValue)") { $0.update(ids, change) }
    }

    func deleteSelection() {
        if let edge = activeConnection {
            edit { $0.removeConnection(edge.id) }
            selectedConnection = nil
            return
        }
        let ids = doc.carried(by: selection)
        guard !ids.isEmpty else { return }
        edit { $0.remove(ids) }
        prune()
    }

    func duplicateSelection() {
        let ids = doc.carried(by: selection)
        guard !ids.isEmpty else { return }
        let sources = doc.nodes.filter { ids.contains($0.id) }.map(\.id)
        var copies: [UUID] = []
        edit { copies = $0.duplicate(ids) }
        selection = Set(zip(sources, copies).filter { selection.contains($0.0) }.map(\.1))
    }

    func selectAll() {
        selectedConnection = nil
        selection = Set(doc.nodes.filter { !$0.isLocked && !$0.isHidden }.map(\.id))
    }

    func nudge(_ dx: Double, _ dy: Double) {
        let ids = doc.carried(by: selection)
        guard !ids.isEmpty else { return }
        edit(coalescing: "nudge:\(ids.hashValue)") { $0.move(ids, by: CGSize(width: dx, height: dy)) }
    }

    func reorder(toFront: Bool) {
        let ids = editableSelection
        guard !ids.isEmpty else { return }
        edit { $0.reorder(ids, toFront: toFront) }
    }

    func step(forward: Bool) {
        // Start from the end being moved toward so selected neighbors do not leapfrog each other.
        let ordered = doc.nodes.filter { editableSelection.contains($0.id) }.map(\.id)
        guard !ordered.isEmpty else { return }
        edit { doc in for id in forward ? ordered.reversed() : ordered { doc.step(id, forward: forward) } }
    }

    func frameSelection() {
        let ids = editableSelection
        guard !ids.isEmpty else { return }
        var frame: UUID?
        edit { frame = $0.wrapInFrame(ids) }
        if let frame { selection = [frame] }
    }

    /// Removes selected frames and keeps what they held.
    func ungroup() {
        let frames = Set(selectedNodes.filter { $0.kind == .frame && !$0.isLocked }.map(\.id))
        guard !frames.isEmpty else { return }
        let held = frames.reduce(into: Set<UUID>()) { $0.formUnion(doc.children(of: $1)) }.subtracting(frames)
        edit { $0.remove(frames) }
        selection = held
    }

    func setLocked(_ locked: Bool) {
        let ids = selection
        edit { doc in for id in ids { doc.setLocked(id, locked) } }
    }

    func setHidden(_ hidden: Bool) {
        let ids = selection
        edit { doc in for id in ids { doc.setHidden(id, hidden) } }
    }

    /// One layer aligns inside the frame that holds it; several align to each other.
    func align(_ alignment: DesignDocument.Alignment) {
        let ids = editableSelection
        let container = ids.count == 1 ? doc.parents[ids.first!].flatMap { doc.node($0)?.bounds } : nil
        edit { $0.align(ids, alignment, within: container) }
    }

    var canAlign: Bool {
        editableSelection.count > 1 || (editableSelection.count == 1 && doc.parents[editableSelection.first!] != nil)
    }

    func distribute(_ axis: DesignDocument.Axis) {
        let ids = editableSelection
        edit { $0.distribute(ids, axis) }
    }

    // MARK: Clipboard

    @discardableResult
    func copySelection() -> Bool {
        let clip = doc.clip(doc.carried(by: selection))
        guard !clip.nodes.isEmpty, let data = try? JSONEncoder().encode(clip) else { return false }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(data, forType: Self.pasteboardType)
        let text = clip.nodes.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
        if !text.isEmpty { board.setString(text, forType: .string) }
        return true
    }

    var canPaste: Bool {
        NSPasteboard.general.availableType(from: [Self.pasteboardType, .string]) != nil
    }

    /// Pastes copied layers beside their originals while those are in view, or at `location`.
    func paste(at location: CGPoint? = nil) {
        let board = NSPasteboard.general
        let middle = toDoc(CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
        if let data = board.data(forType: Self.pasteboardType), let clip = try? JSONDecoder().decode(DesignClip.self, from: data),
           !clip.nodes.isEmpty, clip.nodes.count <= 2_000 {
            var center = location.map(toDoc)
            let visible = CGRect(origin: toDoc(.zero), size: CGSize(width: canvasSize.width / zoom, height: canvasSize.height / zoom))
            if center == nil, !clip.nodes.contains(where: { visible.intersects($0.bounds.offsetBy(dx: 16, dy: 16)) }) { center = middle }
            var pasted: [UUID] = []
            edit { pasted = $0.paste(clip, centeredAt: center) }
            selection = Set(pasted); selectedConnection = nil
        } else if let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            var created: UUID?
            edit { doc in
                let id = doc.add(.text, in: CGRect(origin: location.map(toDoc) ?? middle, size: CGSize(width: 100, height: 24)))
                doc.update([id]) { node in
                    node.text = String(text.prefix(10_000))
                    let size = DesignText.size(of: node.text, in: node, width: 480)
                    node.width = ceil(size.width) + 2; node.height = ceil(size.height)
                }
                created = id
            }
            if let created { selection = [created]; selectedConnection = nil }
        }
    }

    // MARK: Text

    func beginEditing(_ id: UUID, isNew: Bool = false, autoSizes: Bool = false) {
        guard let node = doc.node(id), !node.isLocked, !node.isHidden, !node.isLinear else { return }
        editingIsNew = isNew; editingAutoSizes = autoSizes
        selection = [id]; selectedConnection = nil
        editingText = id
    }

    func updateText(_ text: String) {
        guard let id = editingText else { return }
        let grows = editingAutoSizes
        edit(coalescing: "text:\(id)") { doc in
            doc.update([id]) { node in
                node.text = String(text.prefix(10_000))
                guard node.kind == .text else { return }
                if grows {
                    let size = DesignText.size(of: node.text.isEmpty ? " " : node.text, in: node, width: nil)
                    node.width = ceil(size.width) + 4; node.height = ceil(size.height)
                } else {
                    Self.growToFit(&node)
                }
            }
        }
    }

    /// A text layer grows downward rather than clipping what was typed into it.
    static func growToFit(_ node: inout DesignNode) {
        guard node.kind == .text else { return }
        node.height = max(node.height, ceil(DesignText.size(of: node.text, in: node, width: node.width).height))
    }

    func commitText() {
        guard let id = editingText else { return }
        editingText = nil
        if editingIsNew, doc.node(id)?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            edit { $0.remove([id]) }
            prune()
        }
        editingIsNew = false; editingAutoSizes = false
        focusRequests += 1
    }

    // MARK: Chat and export

    var hasDesignReference: Bool {
        doc.nodes.contains { selection.isEmpty ? !$0.isHidden : selection.contains($0.id) }
    }

    func useInChat() {
        guard !preparingReference, let app else { return }
        preparingReference = true
        let ids = selection
        Task {
            defer { preparingReference = false }
            do { try await app.useDesignElementsInChat(projectID: projectID, selection: ids) }
            catch { report("Couldn't use design in chat", error) }
        }
    }

    private func report(_ title: String, _ error: Error) {
        errorTitle = title; errorMessage = error.localizedDescription
    }

    func copyImage() {
        do {
            let png = try DesignRenderer.png(document: doc, selection: selection)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(png, forType: .png)
        } catch { report("Couldn't copy design", error) }
    }

    func export() {
        do {
            let png = try DesignRenderer.png(document: doc, selection: selection)
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
                throw DesignToolError("Open a project window to export.")
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            let project = app?.project(id: projectID)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.directoryURL = project?.url
            let name = String((project?.name ?? "Marika").map { "/\\:".contains($0) ? "-" : $0 }.prefix(90))
            panel.nameFieldStringValue = "\(name) design.png"
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                Task {
                    do { try await Task.detached { try png.write(to: url, options: .atomic) }.value }
                    catch { self?.report("Couldn't export design", error) }
                }
            }
        } catch { report("Couldn't export design", error) }
    }
    func exportSVG() {
        do {
            let data = Data(try DesignSVG.render(doc, selection: selection).utf8)
            let panel = NSSavePanel(); panel.allowedContentTypes = [.svg]; panel.canCreateDirectories = true
            panel.nameFieldStringValue = "Design.svg"
            if let project = app?.project(id: projectID) { panel.directoryURL = project.url }
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                do { try data.write(to: url, options: .atomic) } catch { self?.report("Couldn't export SVG", error) }
            }
        } catch { report("Couldn't export SVG", error) }
    }
}
