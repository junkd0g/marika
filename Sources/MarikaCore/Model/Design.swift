import Foundation

public struct DesignColor: Codable, Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    public static let white = DesignColor(1, 1, 1)
    public static let black = DesignColor(0.1, 0.1, 0.12)
    public static let blue = DesignColor(0.25, 0.5, 1)
    public static let gray = DesignColor(0.88, 0.88, 0.9)

    public var clamped: DesignColor {
        func component(_ value: Double, fallback: Double) -> Double { value.isFinite ? min(1, max(0, value)) : fallback }
        return DesignColor(component(red, fallback: 0), component(green, fallback: 0),
                           component(blue, fallback: 0), component(alpha, fallback: 1))
    }

    /// `#RRGGBB`, with an alpha pair only when the color is translucent.
    public var hex: String {
        let value = clamped
        func byte(_ component: Double) -> Int { Int((component * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", byte(value.red), byte(value.green), byte(value.blue))
        return value.alpha == 1 ? rgb : rgb + String(format: "%02X", byte(value.alpha))
    }

    /// Accepts `RGB`, `RRGGBB` or `RRGGBBAA`, with or without a leading `#`.
    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard [6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        let rgb = digits.count == 8 ? value >> 8 : value
        self.init(Double((rgb >> 16) & 255) / 255, Double((rgb >> 8) & 255) / 255, Double(rgb & 255) / 255,
                  digits.count == 8 ? Double(value & 255) / 255 : 1)
    }
}

public enum DesignHandle: String, Codable, CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// -1 when the handle drags the left edge, 1 for the right edge, 0 when it leaves both alone.
    public var horizontal: Int {
        switch self { case .topLeft, .left, .bottomLeft: -1; case .topRight, .right, .bottomRight: 1; case .top, .bottom: 0 }
    }
    /// -1 when the handle drags the top edge, 1 for the bottom edge, 0 when it leaves both alone.
    public var vertical: Int {
        switch self { case .topLeft, .top, .topRight: -1; case .bottomLeft, .bottom, .bottomRight: 1; case .left, .right: 0 }
    }

    public func point(in rect: CGRect) -> CGPoint {
        CGPoint(x: horizontal < 0 ? rect.minX : horizontal > 0 ? rect.maxX : rect.midX,
                y: vertical < 0 ? rect.minY : vertical > 0 ? rect.maxY : rect.midY)
    }

    /// Drags this handle of `rect` to `point`, holding the opposite edge (or the center) in place.
    public func resize(_ rect: CGRect, to point: CGPoint, keepAspect: Bool = false, fromCenter: Bool = false,
                       minimum: Double = DesignDocument.minimumSize) -> CGRect {
        let px = Double(point.x), py = Double(point.y), midX = Double(rect.midX), midY = Double(rect.midY)
        var minX = Double(rect.minX), maxX = Double(rect.maxX), minY = Double(rect.minY), maxY = Double(rect.maxY)
        if horizontal < 0 {
            minX = min(px, fromCenter ? midX - minimum / 2 : maxX - minimum)
            if fromCenter { maxX = 2 * midX - minX }
        } else if horizontal > 0 {
            maxX = max(px, fromCenter ? midX + minimum / 2 : minX + minimum)
            if fromCenter { minX = 2 * midX - maxX }
        }
        if vertical < 0 {
            minY = min(py, fromCenter ? midY - minimum / 2 : maxY - minimum)
            if fromCenter { maxY = 2 * midY - minY }
        } else if vertical > 0 {
            maxY = max(py, fromCenter ? midY + minimum / 2 : minY + minimum)
            if fromCenter { minY = 2 * midY - maxY }
        }
        var width = maxX - minX, height = maxY - minY
        guard keepAspect, rect.width > 0, rect.height > 0 else { return CGRect(x: minX, y: minY, width: width, height: height) }
        let ratio = Double(rect.width / rect.height)
        if vertical == 0 || (horizontal != 0 && width / Double(rect.width) >= height / Double(rect.height)) {
            height = width / ratio
        } else {
            width = height * ratio
        }
        if width < minimum { width = minimum; height = width / ratio }
        if height < minimum { height = minimum; width = height * ratio }
        let x = fromCenter || horizontal == 0 ? midX - width / 2 : horizontal < 0 ? Double(rect.maxX) - width : Double(rect.minX)
        let y = fromCenter || vertical == 0 ? midY - height / 2 : vertical < 0 ? Double(rect.maxY) - height : Double(rect.minY)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

public struct DesignConnection: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var from: UUID
    public var to: UUID
    public var label: String
    public var fromPort: DesignPort?
    public var toPort: DesignPort?
    public var style: DesignFlow?
    public var labelPosition: Double?
    public var avoidsObstacles: Bool?

    public init(id: UUID = UUID(), from: UUID, to: UUID, label: String = "") {
        self.id = id; self.from = from; self.to = to; self.label = label
    }

    /// Attached endpoints follow their shapes when a user moves or resizes them.
    public func route(in nodes: [DesignNode]) -> [CGPoint]? { DesignRouter.route(self, nodes: nodes) }
}

public enum DesignFontWeight: String, Codable, CaseIterable, Sendable { case regular, medium, semibold, bold }
public enum DesignTextAlign: String, Codable, CaseIterable, Sendable { case left, center, right }
public enum DesignStrokeStyle: String, Codable, CaseIterable, Sendable { case solid, dashed, dotted }

public struct DesignShadow: Codable, Equatable, Hashable, Sendable {
    public var color: DesignColor
    public var x: Double
    public var y: Double
    public var blur: Double
    public init(color: DesignColor = DesignColor(0, 0, 0, 0.25), x: Double = 0, y: Double = 4, blur: Double = 12) {
        self.color = color; self.x = x; self.y = y; self.blur = blur
    }
}

public struct DesignNode: Codable, Equatable, Hashable, Sendable, Identifiable {
    public static let maximumDescriptionLength = 8_000
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case frame = "Frame", rectangle = "Rectangle", ellipse = "Ellipse", polygon = "Polygon", star = "Star"
        case line = "Line", arrow = "Arrow", text = "Text"
        public var symbol: String {
            switch self {
            case .frame: "number.square"
            case .rectangle: "rectangle"
            case .ellipse: "circle"
            case .polygon: "triangle"
            case .star: "star"
            case .line: "line.diagonal"
            case .arrow: "arrow.up.right"
            case .text: "textformat"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    public var name: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var fill: DesignColor
    public var stroke: DesignColor?
    public var strokeWidth: Double
    public var cornerRadius: Double
    public var opacity: Double
    public var text: String
    /// Behavioral and implementation notes; kept separate from the visible label.
    public var description: String?
    public var fontSize: Double
    public var isLocked: Bool
    public var isHidden: Bool
    // Everything below is optional so canvases saved by earlier versions still decode.
    /// Clockwise degrees around the center. `x`, `y`, `width` and `height` describe the box before rotation.
    public var rotation: Double?
    /// Corners of a polygon or points of a star.
    public var sides: Int?
    public var fontWeight: DesignFontWeight?
    public var textAlign: DesignTextAlign?
    public var strokeStyle: DesignStrokeStyle?
    public var shadow: DesignShadow?
    /// Optional engineering role; older, generic shapes have no component badge.
    public var component: DesignComponent?
    public var links: [DesignSourceLink]?

    public init(id: UUID = UUID(), kind: Kind, name: String? = nil, x: Double, y: Double, width: Double, height: Double) {
        self.id = id; self.kind = kind; self.name = name ?? kind.rawValue
        self.x = x; self.y = y; self.width = width; self.height = height
        switch kind {
        case .frame: fill = .white; stroke = nil
        case .rectangle, .ellipse, .polygon, .star: fill = .blue; stroke = nil
        case .line, .arrow: fill = .black; stroke = .black
        case .text: fill = .black; stroke = nil
        }
        strokeWidth = kind == .line || kind == .arrow ? 2 : 1
        cornerRadius = 0; opacity = 1; text = kind == .text ? "Text" : ""; fontSize = 18
        isLocked = false; isHidden = false
        normalize()
    }

    public mutating func normalize(fallback: DesignNode? = nil) {
        func bounded(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        x = bounded(x, -100_000...100_000, fallback?.x ?? 0)
        y = bounded(y, -100_000...100_000, fallback?.y ?? 0)
        width = bounded(width, DesignDocument.minimumSize...20_000, fallback?.width ?? 100)
        height = bounded(height, DesignDocument.minimumSize...20_000, fallback?.height ?? 100)
        fontSize = bounded(fontSize, 1...500, fallback?.fontSize ?? 18)
        strokeWidth = bounded(strokeWidth, 0...100, fallback?.strokeWidth ?? 1)
        cornerRadius = bounded(cornerRadius, 0...20_000, fallback?.cornerRadius ?? 0)
        opacity = bounded(opacity, 0...1, fallback?.opacity ?? 1)
        fill = fill.clamped; stroke = stroke?.clamped
        if let value = description {
            description = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : String(value.prefix(Self.maximumDescriptionLength))
        }
        // Defaults are stored as nil so equal-looking canvases keep equal revisions.
        if let value = rotation {
            var degrees = value.isFinite ? value.truncatingRemainder(dividingBy: 360) : fallback?.rotation ?? 0
            if degrees > 180 { degrees -= 360 } else if degrees <= -180 { degrees += 360 }
            degrees = (degrees * 100).rounded() / 100
            rotation = degrees == 0 ? nil : degrees
        }
        sides = kind == .polygon || kind == .star ? sides.map { min(12, max(3, $0)) } : nil
        if strokeStyle == .solid { strokeStyle = nil }
        if isLinear || kind == .frame || kind == .text { component = nil }
        if let links { self.links = Array(links.filter(\.isValid).prefix(20)); if self.links?.isEmpty == true { self.links = nil } }
        if let value = shadow {
            shadow = DesignShadow(color: value.color.clamped, x: bounded(value.x, -1_000...1_000, 0),
                                  y: bounded(value.y, -1_000...1_000, 4), blur: bounded(value.blur, 0...1_000, 12))
        }
    }

    // MARK: Geometry

    public var isLinear: Bool { kind == .line || kind == .arrow }
    public var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public var center: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }
    public var radians: Double { (rotation ?? 0) * .pi / 180 }

    private func turned(_ point: CGPoint, by angle: Double) -> CGPoint {
        guard angle != 0 else { return point }
        let cx = x + width / 2, cy = y + height / 2
        let dx = Double(point.x) - cx, dy = Double(point.y) - cy
        return CGPoint(x: cx + dx * cos(angle) - dy * sin(angle), y: cy + dx * sin(angle) + dy * cos(angle))
    }
    /// Maps a point in the unrotated box onto the canvas.
    public func toWorld(_ point: CGPoint) -> CGPoint { turned(point, by: radians) }
    /// Maps a canvas point into the unrotated box, where edges are axis-aligned.
    public func toLocal(_ point: CGPoint) -> CGPoint { turned(point, by: -radians) }

    /// Top-left, top-right, bottom-right and bottom-left after rotation.
    public var corners: [CGPoint] {
        [CGPoint(x: x, y: y), CGPoint(x: x + width, y: y), CGPoint(x: x + width, y: y + height), CGPoint(x: x, y: y + height)].map(toWorld)
    }

    /// The axis-aligned box around the rotated layer; equal to `frame` without rotation.
    public var bounds: CGRect {
        guard rotation != nil else { return frame }
        let xs = corners.map { Double($0.x) }, ys = corners.map { Double($0.y) }
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Bounds plus whatever is painted outside them, for fitting and export.
    public var visualBounds: CGRect {
        var box = bounds
        if isLinear { let reach = max(0, strokeWidth * 2 + 4 - height / 2); box = box.insetBy(dx: -reach, dy: -reach) }
        if let shadow {
            box = box.union(box.offsetBy(dx: shadow.x, dy: shadow.y).insetBy(dx: -shadow.blur, dy: -shadow.blur))
        }
        return box
    }

    /// A line runs along the horizontal middle of its box, so its ends rotate with it.
    public var endpoints: (start: CGPoint, end: CGPoint) {
        (toWorld(CGPoint(x: x, y: y + height / 2)), toWorld(CGPoint(x: x + width, y: y + height / 2)))
    }

    public mutating func setEndpoints(_ start: CGPoint, _ end: CGPoint) {
        let dx = Double(end.x - start.x), dy = Double(end.y - start.y)
        width = max(DesignDocument.minimumSize, (dx * dx + dy * dy).squareRoot())
        x = Double(start.x + end.x) / 2 - width / 2
        y = Double(start.y + end.y) / 2 - height / 2
        rotation = atan2(dy, dx) * 180 / .pi
        normalize()
    }

    /// Polygon corners or star points, scaled so the shape fills `rect`.
    public static func outline(_ kind: Kind, sides: Int?, in rect: CGRect) -> [CGPoint] {
        guard kind == .polygon || kind == .star else { return [] }
        let count = min(12, max(3, sides ?? (kind == .star ? 5 : 3))) * (kind == .star ? 2 : 1)
        let unit = (0..<count).map { index -> CGPoint in
            let angle = -Double.pi / 2 + Double(index) * 2 * .pi / Double(count)
            let radius = kind == .star && index % 2 == 1 ? 0.382 : 1
            return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        }
        let xs = unit.map { Double($0.x) }, ys = unit.map { Double($0.y) }
        let minX = xs.min()!, minY = ys.min()!, spanX = xs.max()! - minX, spanY = ys.max()! - minY
        return unit.map { CGPoint(x: Double(rect.minX) + (Double($0.x) - minX) / spanX * Double(rect.width),
                                  y: Double(rect.minY) + (Double($0.y) - minY) / spanY * Double(rect.height)) }
    }

    /// `slop` widens the target so thin layers such as lines stay easy to click.
    public func contains(_ point: CGPoint, slop: Double = 0) -> Bool {
        let local = toLocal(point)
        guard frame.insetBy(dx: -slop, dy: -slop).contains(local) else { return false }
        switch kind {
        case .ellipse:
            let dx = (local.x - frame.midX) / max(1, width / 2 + slop), dy = (local.y - frame.midY) / max(1, height / 2 + slop)
            return dx * dx + dy * dy <= 1
        case .polygon, .star:
            let points = Self.outline(kind, sides: sides, in: frame)
            var inside = false
            for (a, b) in zip(points, points.dropFirst() + points.prefix(1)) where (a.y > local.y) != (b.y > local.y) {
                if local.x < (b.x - a.x) * (local.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            }
            return inside
        case .frame, .rectangle, .line, .arrow, .text:
            return true
        }
    }

    /// Drags one resize handle to a canvas point. A rotated layer resizes along its own axes.
    public func resized(_ handle: DesignHandle, to point: CGPoint, keepAspect: Bool = false, fromCenter: Bool = false) -> DesignNode {
        let rect = handle.resize(frame, to: toLocal(point), keepAspect: keepAspect, fromCenter: fromCenter)
        let middle = toWorld(CGPoint(x: rect.midX, y: rect.midY))
        var copy = self
        copy.width = rect.width; copy.height = rect.height
        copy.x = middle.x - rect.width / 2; copy.y = middle.y - rect.height / 2
        return copy
    }

    /// Follows a selection box as it is resized from `old` to `new`.
    public func scaled(from old: CGRect, to new: CGRect) -> DesignNode {
        guard old.width > 0, old.height > 0 else { return self }
        let sx = Double(new.width / old.width), sy = Double(new.height / old.height)
        // A quarter turn swaps the axes; other angles cannot stretch without skewing, so they scale evenly.
        let turn = abs(sin(radians))
        let (across, along) = turn < 0.01 ? (sx, sy) : turn > 0.99 ? (sy, sx) : ((sx * sy).squareRoot(), (sx * sy).squareRoot())
        var copy = self
        copy.width = max(DesignDocument.minimumSize, width * across)
        if !isLinear { copy.height = max(DesignDocument.minimumSize, height * along) }
        copy.x = Double(new.minX) + (Double(center.x) - Double(old.minX)) * sx - copy.width / 2
        copy.y = Double(new.minY) + (Double(center.y) - Double(old.minY)) * sy - copy.height / 2
        return copy
    }
}

/// Copied layers and the connections that run between them.
public struct DesignClip: Codable, Equatable, Sendable {
    public var nodes: [DesignNode]
    public var connections: [DesignConnection]
    public init(nodes: [DesignNode], connections: [DesignConnection] = []) {
        self.nodes = nodes; self.connections = connections
    }
}

/// One visible row in the front-to-back layer tree. Frames contain their descendants.
public struct DesignLayerEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let parentID: UUID?
    public let depth: Int
    public let hasChildren: Bool
}

/// A single infinite canvas. `nodes` run back to front, so later nodes draw above earlier ones.
public struct DesignDocument: Codable, Equatable, Hashable, Sendable {
    public static let minimumSize = 8.0
    public var nodes: [DesignNode] = []
    public var title: String?
    /// Optional so canvases saved before chat integration still decode.
    public var connections: [DesignConnection]?
    public init() {}

    public func node(_ id: UUID) -> DesignNode? { nodes.first { $0.id == id } }

    /// Topmost visible, unlocked node under `point`.
    public func hitTest(_ point: CGPoint, slop: Double = 0, skipping: Set<UUID> = []) -> UUID? {
        nodes.last { !$0.isHidden && !$0.isLocked && !skipping.contains($0.id) && $0.contains(point, slop: slop) }?.id
    }

    /// Unlocked, visible nodes whose bounds touch `rect`, used for marquee selection.
    public func nodes(in rect: CGRect) -> [UUID] {
        nodes.filter { !$0.isHidden && !$0.isLocked && rect.intersects($0.bounds) }.map(\.id)
    }

    public func bounds(of ids: Set<UUID>) -> CGRect? {
        nodes.filter { ids.contains($0.id) }.map(\.bounds).reduce(nil as CGRect?) { partial, box in partial.map { $0.union(box) } ?? box }
    }

    public var visibleBounds: CGRect? {
        nodes.filter { !$0.isHidden }.map(\.visualBounds).reduce(nil as CGRect?) { partial, box in partial.map { $0.union(box) } ?? box }
    }
    public var editableIDs: Set<UUID> { Set(nodes.filter { !$0.isLocked }.map(\.id)) }

    public mutating func normalize() {
        for index in nodes.indices { nodes[index].normalize() }
        if connections?.isEmpty == true { connections = nil }
    }

    // MARK: Frames

    /// The innermost visible frame beneath each layer that fully contains it.
    public var parents: [UUID: UUID] {
        var result: [UUID: UUID] = [:]
        var frames: [(id: UUID, box: CGRect)] = []
        for node in nodes {
            let box = node.bounds
            if let parent = frames.last(where: { $0.box.contains(box) }) { result[node.id] = parent.id }
            if node.kind == .frame, !node.isHidden { frames.append((node.id, box)) }
        }
        return result
    }

    public func layerHierarchy(collapsing collapsed: Set<UUID> = []) -> [DesignLayerEntry] {
        let parents = parents
        let groups = Dictionary(grouping: nodes.reversed()) { parents[$0.id] }
        var rows: [DesignLayerEntry] = []
        func append(_ parent: UUID?, depth: Int) {
            for node in groups[parent] ?? [] {
                rows.append(DesignLayerEntry(id: node.id, parentID: parent, depth: depth,
                                             hasChildren: groups[node.id]?.isEmpty == false))
                if !collapsed.contains(node.id) { append(node.id, depth: depth + 1) }
            }
        }
        append(nil, depth: 0)
        return rows
    }

    /// Reorders sibling rows while carrying frame contents and preserving locked layers.
    /// A nil destination puts them at the back of their current parent, without reparenting.
    public mutating func reorderLayers(_ ids: Set<UUID>, before target: UUID?) {
        let parents = parents
        guard let first = nodes.first(where: { ids.contains($0.id) }),
              ids.allSatisfy({ node($0) != nil && parents[$0] == parents[first.id] }),
              target.map({ !ids.contains($0) && node($0) != nil && parents[$0] == parents[first.id] }) ?? true else { return }
        func belongs(_ id: UUID, to roots: Set<UUID>) -> Bool {
            var current: UUID? = id
            while let value = current {
                if roots.contains(value) { return true }
                current = parents[value]
            }
            return false
        }
        let moved = nodes.filter { belongs($0.id, to: ids) }
        guard moved.allSatisfy({ !$0.isLocked }) else { return }
        nodes.removeAll { belongs($0.id, to: ids) }
        let insertion: Int
        if let target {
            insertion = (nodes.lastIndex { belongs($0.id, to: [target]) } ?? -1) + 1
        } else if let parent = parents[first.id] {
            insertion = (nodes.firstIndex { $0.id == parent } ?? -1) + 1
        } else {
            insertion = 0
        }
        nodes.insert(contentsOf: moved, at: insertion)
    }

    /// A frame holds the layers drawn above it that sit entirely inside its bounds.
    public func children(of id: UUID) -> Set<UUID> {
        guard let index = nodes.firstIndex(where: { $0.id == id }), nodes[index].kind == .frame, !nodes[index].isHidden else { return [] }
        let box = nodes[index].bounds
        return Set(nodes[(index + 1)...].filter { box.contains($0.bounds) }.map(\.id))
    }

    /// `ids` plus everything their frames hold. Exporting or referencing a frame includes its contents.
    public func withChildren(_ ids: Set<UUID>) -> Set<UUID> {
        ids.reduce(into: ids) { $0.formUnion(children(of: $1)) }
    }

    /// `withChildren` without locked layers. Moving, copying and deleting act on this set.
    public func carried(by ids: Set<UUID>) -> Set<UUID> { withChildren(ids).intersection(editableIDs) }

    /// Wraps the layers in a new frame placed directly beneath them.
    @discardableResult
    public mutating func wrapInFrame(_ ids: Set<UUID>) -> UUID? {
        guard let box = bounds(of: ids), let lowest = nodes.firstIndex(where: { ids.contains($0.id) }) else { return nil }
        let frame = DesignNode(kind: .frame, name: nextName(.frame), x: box.minX, y: box.minY, width: box.width, height: box.height)
        nodes.insert(frame, at: lowest)
        return frame.id
    }

    // MARK: Editing

    private func nextName(_ kind: DesignNode.Kind) -> String { "\(kind.rawValue) \(nodes.filter { $0.kind == kind }.count + 1)" }

    @discardableResult
    public mutating func add(_ kind: DesignNode.Kind, in rect: CGRect) -> UUID {
        let node = DesignNode(kind: kind, name: nextName(kind), x: rect.minX, y: rect.minY,
                              width: max(Self.minimumSize, rect.width), height: max(Self.minimumSize, rect.height))
        // A frame drawn around existing layers slides beneath them so it holds them instead of covering them.
        let lowest = kind == .frame ? nodes.firstIndex { !$0.isHidden && node.frame.contains($0.bounds) } : nil
        nodes.insert(node, at: lowest ?? nodes.endIndex)
        return node.id
    }

    @discardableResult
    public mutating func addLine(_ kind: DesignNode.Kind, from start: CGPoint, to end: CGPoint) -> UUID {
        var node = DesignNode(kind: kind, name: nextName(kind), x: 0, y: 0, width: 100, height: 16)
        node.setEndpoints(start, end)
        nodes.append(node)
        return node.id
    }

    public mutating func move(_ ids: Set<UUID>, by delta: CGSize) {
        guard delta.width.isFinite, delta.height.isFinite else { return }
        for index in nodes.indices where ids.contains(nodes[index].id) && !nodes[index].isLocked {
            nodes[index].x += delta.width; nodes[index].y += delta.height
            nodes[index].normalize()
        }
    }

    public mutating func resize(_ id: UUID, handle: DesignHandle, to point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite, let node = node(id) else { return }
        apply([id: node.resized(handle, to: point)])
    }

    /// Replaces unlocked layers by ID, as produced by a drag that recomputes from where it started.
    public mutating func apply(_ replacements: [UUID: DesignNode]) {
        for index in nodes.indices where !nodes[index].isLocked {
            guard var next = replacements[nodes[index].id] else { continue }
            next.normalize(fallback: nodes[index])
            nodes[index] = next
        }
    }

    public mutating func remove(_ ids: Set<UUID>) {
        let removed = ids.intersection(editableIDs)
        nodes.removeAll { removed.contains($0.id) }
        connections?.removeAll { removed.contains($0.from) || removed.contains($0.to) }
    }

    public func clip(_ ids: Set<UUID>) -> DesignClip {
        DesignClip(nodes: nodes.filter { ids.contains($0.id) },
                   connections: (connections ?? []).filter { ids.contains($0.from) && ids.contains($0.to) })
    }

    private mutating func insertCopies(of clip: DesignClip, delta: CGSize, suffix: String) -> [UUID] {
        var copies: [UUID: UUID] = [:]
        var created: [UUID] = []
        for node in clip.nodes {
            var copy = node
            copy.id = UUID(); copy.x += delta.width; copy.y += delta.height; copy.name = node.name + suffix
            copy.isLocked = false
            copy.normalize()
            copies[node.id] = copy.id
            created.append(copy.id)
            nodes.append(copy)
        }
        let edges = clip.connections.compactMap { edge -> DesignConnection? in
            guard let from = copies[edge.from], let to = copies[edge.to] else { return nil }
            return DesignConnection(from: from, to: to, label: edge.label)
        }
        if !edges.isEmpty { connections = (connections ?? []) + edges }
        return created
    }

    @discardableResult
    public mutating func duplicate(_ ids: Set<UUID>, offset: Double = 16) -> [UUID] {
        insertCopies(of: clip(ids.intersection(editableIDs)), delta: CGSize(width: offset, height: offset), suffix: " copy")
    }

    /// Adds copied layers with fresh identities, centered on `center` when given.
    @discardableResult
    public mutating func paste(_ clip: DesignClip, centeredAt center: CGPoint? = nil, offset: Double = 16) -> [UUID] {
        var delta = CGSize(width: offset, height: offset)
        if let center, let box = clip.nodes.map(\.bounds).reduce(nil as CGRect?, { partial, box in partial.map { $0.union(box) } ?? box }) {
            delta = CGSize(width: (center.x - box.midX).rounded(), height: (center.y - box.midY).rounded())
        }
        return insertCopies(of: clip, delta: delta, suffix: "")
    }

    public mutating func reorder(_ ids: Set<UUID>, toFront: Bool) {
        let parents = parents
        let editable = ids.intersection(editableIDs).filter { id in
            var parent = parents[id]
            while let value = parent {
                if ids.contains(value) { return false }
                parent = parents[value]
            }
            return true
        }
        let groups = Dictionary(grouping: editable) { parents[$0] }
        for (parent, group) in groups {
            let picked = Set(group)
            let target = toFront ? nodes.reversed().first { parents[$0.id] == parent && !picked.contains($0.id) }?.id : nil
            reorderLayers(picked, before: target)
        }
    }

    public mutating func step(_ id: UUID, forward: Bool) {
        let parents = parents
        let siblings = nodes.reversed().filter { parents[$0.id] == parents[id] }
        guard let index = siblings.firstIndex(where: { $0.id == id }), !siblings[index].isLocked else { return }
        if forward, index > 0 { reorderLayers([id], before: siblings[index - 1].id) }
        if !forward, index + 1 < siblings.count {
            reorderLayers([id], before: index + 2 < siblings.count ? siblings[index + 2].id : nil)
        }
    }

    public mutating func update(_ ids: Set<UUID>, _ change: (inout DesignNode) -> Void) {
        for index in nodes.indices where ids.contains(nodes[index].id) && !nodes[index].isLocked {
            let previous = nodes[index]
            change(&nodes[index]); nodes[index].normalize(fallback: previous)
        }
    }

    public mutating func setLocked(_ id: UUID, _ locked: Bool) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[index].isLocked = locked
    }

    public mutating func setHidden(_ id: UUID, _ hidden: Bool) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[index].isHidden = hidden
    }

    /// Align selected nodes to the edges or centers of their shared bounds, or of `container` when given.
    public enum Alignment: Sendable { case left, centerX, right, top, centerY, bottom }
    public mutating func align(_ ids: Set<UUID>, _ alignment: Alignment, within container: CGRect? = nil) {
        guard let box = container ?? (ids.count > 1 ? bounds(of: ids) : nil) else { return }
        for index in nodes.indices where ids.contains(nodes[index].id) && !nodes[index].isLocked {
            let own = nodes[index].bounds
            switch alignment {
            case .left: nodes[index].x += box.minX - own.minX
            case .centerX: nodes[index].x += box.midX - own.midX
            case .right: nodes[index].x += box.maxX - own.maxX
            case .top: nodes[index].y += box.minY - own.minY
            case .centerY: nodes[index].y += box.midY - own.midY
            case .bottom: nodes[index].y += box.maxY - own.maxY
            }
            nodes[index].normalize()
        }
    }

    /// Evens out the gaps between three or more layers, leaving the outermost two in place.
    public enum Axis: Sendable { case horizontal, vertical }
    public mutating func distribute(_ ids: Set<UUID>, _ axis: Axis) {
        func start(_ node: DesignNode) -> Double { Double(axis == .horizontal ? node.bounds.minX : node.bounds.minY) }
        func extent(_ node: DesignNode) -> Double { Double(axis == .horizontal ? node.bounds.width : node.bounds.height) }
        let picked = nodes.filter { ids.contains($0.id) && !$0.isLocked }.sorted { start($0) < start($1) }
        guard picked.count > 2, let first = picked.first, let last = picked.last else { return }
        let gap = (start(last) + extent(last) - start(first) - picked.map(extent).reduce(0, +)) / Double(picked.count - 1)
        var cursor = start(first)
        var moved: [UUID: DesignNode] = [:]
        for var node in picked {
            if axis == .horizontal { node.x += cursor - start(node) } else { node.y += cursor - start(node) }
            cursor += extent(node) + gap
            moved[node.id] = node
        }
        apply(moved)
    }

    // MARK: Connections

    /// Joins two layers with an arrow, reusing the connection if it already exists.
    @discardableResult
    public mutating func connect(_ from: UUID, _ to: UUID, label: String = "") -> UUID? {
        guard from != to, node(from) != nil, node(to) != nil else { return nil }
        if let existing = connections?.first(where: { $0.from == from && $0.to == to }) { return existing.id }
        let edge = DesignConnection(from: from, to: to, label: label)
        connections = (connections ?? []) + [edge]
        return edge.id
    }

    public mutating func removeConnection(_ id: UUID) { connections?.removeAll { $0.id == id } }

    public mutating func updateConnection(_ id: UUID, _ change: (inout DesignConnection) -> Void) {
        guard let index = connections?.firstIndex(where: { $0.id == id }) else { return }
        change(&connections![index])
        connections![index].id = id
        connections![index].label = String(connections![index].label.prefix(500))
    }

    /// Topmost connection whose arrow passes within `tolerance` of `point`.
    public func connection(at point: CGPoint, tolerance: Double) -> UUID? {
        (connections ?? []).last { edge in
            guard let route = edge.route(in: nodes) else { return false }
            return zip(route, route.dropFirst()).contains { a, b in
                let dx = Double(b.x - a.x), dy = Double(b.y - a.y), length = dx * dx + dy * dy
                let along = length == 0 ? 0 : min(1, max(0, (Double(point.x - a.x) * dx + Double(point.y - a.y) * dy) / length))
                let ox = Double(point.x - a.x) - along * dx, oy = Double(point.y - a.y) - along * dy
                return (ox * ox + oy * oy).squareRoot() <= tolerance
            }
        }?.id
    }

    /// Edges and centers that a dragged layer can line up with.
    public func snapTargets(excluding ids: Set<UUID>) -> [CGRect] {
        nodes.filter { !$0.isHidden && !ids.contains($0.id) }.map(\.bounds)
    }
}

/// A smart guide drawn while a drag lines up with another layer.
public struct DesignGuide: Equatable, Hashable, Sendable {
    public enum Axis: Sendable { case vertical, horizontal }
    public var axis: Axis
    /// The x of a vertical guide or the y of a horizontal one.
    public var position: Double
    public var start: Double
    public var end: Double
}

public enum DesignSnap {
    private static func lines(_ rect: CGRect, _ axis: DesignGuide.Axis) -> [Double] {
        (axis == .vertical ? [rect.minX, rect.midX, rect.maxX] : [rect.minY, rect.midY, rect.maxY]).map { Double($0) }
    }

    private static func span(_ rect: CGRect, _ axis: DesignGuide.Axis) -> (Double, Double) {
        axis == .vertical ? (Double(rect.minY), Double(rect.maxY)) : (Double(rect.minX), Double(rect.maxX))
    }

    /// The smallest shift that lines one of `values` up with an edge or center of a target.
    private static func shift(_ values: [Double], targets: [CGRect], axis: DesignGuide.Axis, threshold: Double) -> Double? {
        var best: Double?
        for target in targets {
            for line in lines(target, axis) {
                for value in values where abs(line - value) <= threshold && abs(line - value) < abs(best ?? .infinity) {
                    best = line - value
                }
            }
        }
        return best
    }

    private static func guides(_ values: [Double], extent: (Double, Double), targets: [CGRect], axis: DesignGuide.Axis) -> [DesignGuide] {
        values.compactMap { value in
            let spans = targets.filter { target in lines(target, axis).contains { abs($0 - value) < 0.01 } }.map { span($0, axis) }
            guard !spans.isEmpty else { return nil }
            return DesignGuide(axis: axis, position: value, start: min(extent.0, spans.map { $0.0 }.min()!),
                               end: max(extent.1, spans.map { $0.1 }.max()!))
        }
    }

    /// Nudges a dragged box so its edges or center meet nearby layers.
    public static func move(_ rect: CGRect, targets: [CGRect], threshold: Double,
                            x: Bool = true, y: Bool = true) -> (offset: CGSize, guides: [DesignGuide]) {
        let dx = x ? shift(lines(rect, .vertical), targets: targets, axis: .vertical, threshold: threshold) : nil
        let dy = y ? shift(lines(rect, .horizontal), targets: targets, axis: .horizontal, threshold: threshold) : nil
        let moved = rect.offsetBy(dx: dx ?? 0, dy: dy ?? 0)
        var result: [DesignGuide] = []
        if dx != nil { result += guides(lines(moved, .vertical), extent: span(moved, .vertical), targets: targets, axis: .vertical) }
        if dy != nil { result += guides(lines(moved, .horizontal), extent: span(moved, .horizontal), targets: targets, axis: .horizontal) }
        return (CGSize(width: dx ?? 0, height: dy ?? 0), result)
    }

    /// Pulls a dragged corner or endpoint onto nearby edges and centers.
    public static func point(_ point: CGPoint, targets: [CGRect], threshold: Double,
                             x: Bool = true, y: Bool = true) -> (point: CGPoint, guides: [DesignGuide]) {
        let dx = x ? shift([Double(point.x)], targets: targets, axis: .vertical, threshold: threshold) : nil
        let dy = y ? shift([Double(point.y)], targets: targets, axis: .horizontal, threshold: threshold) : nil
        let mx = Double(point.x) + (dx ?? 0), my = Double(point.y) + (dy ?? 0)
        var result: [DesignGuide] = []
        if dx != nil { result += guides([mx], extent: (my, my), targets: targets, axis: .vertical) }
        if dy != nil { result += guides([my], extent: (mx, mx), targets: targets, axis: .horizontal) }
        return (CGPoint(x: mx, y: my), result)
    }
}
