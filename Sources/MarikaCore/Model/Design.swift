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
}

public enum DesignHandle: String, Codable, CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

public struct DesignNode: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case frame = "Frame", rectangle = "Rectangle", ellipse = "Ellipse", text = "Text"
        public var symbol: String {
            switch self {
            case .frame: "number.square"
            case .rectangle: "rectangle"
            case .ellipse: "circle"
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
    public var fontSize: Double
    public var isLocked: Bool
    public var isHidden: Bool

    public init(id: UUID = UUID(), kind: Kind, name: String? = nil, x: Double, y: Double, width: Double, height: Double) {
        self.id = id; self.kind = kind; self.name = name ?? kind.rawValue
        self.x = x; self.y = y; self.width = width; self.height = height
        switch kind {
        case .frame: fill = .white; stroke = nil
        case .rectangle, .ellipse: fill = .blue; stroke = nil
        case .text: fill = .black; stroke = nil
        }
        strokeWidth = 1; cornerRadius = 0; opacity = 1; text = kind == .text ? "Text" : ""; fontSize = 18
        isLocked = false; isHidden = false
    }

    public var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public func contains(_ point: CGPoint) -> Bool {
        guard kind == .ellipse else { return frame.contains(point) }
        let dx = (point.x - frame.midX) / max(1, width / 2), dy = (point.y - frame.midY) / max(1, height / 2)
        return dx * dx + dy * dy <= 1
    }
}

/// A single infinite canvas. `nodes` run back to front, so later nodes draw above earlier ones.
public struct DesignDocument: Codable, Equatable, Hashable, Sendable {
    public static let minimumSize = 8.0
    public var nodes: [DesignNode] = []
    public init() {}

    public func node(_ id: UUID) -> DesignNode? { nodes.first { $0.id == id } }

    /// Topmost visible, unlocked node under `point`.
    public func hitTest(_ point: CGPoint) -> UUID? {
        nodes.last { !$0.isHidden && !$0.isLocked && $0.contains(point) }?.id
    }

    /// Unlocked, visible nodes whose frames touch `rect`, used for marquee selection.
    public func nodes(in rect: CGRect) -> [UUID] {
        nodes.filter { !$0.isHidden && !$0.isLocked && rect.intersects($0.frame) }.map(\.id)
    }

    public func bounds(of ids: Set<UUID>) -> CGRect? {
        nodes.filter { ids.contains($0.id) }.map(\.frame).reduce(nil as CGRect?) { partial, frame in partial.map { $0.union(frame) } ?? frame }
    }

    @discardableResult
    public mutating func add(_ kind: DesignNode.Kind, in rect: CGRect) -> UUID {
        let count = nodes.filter { $0.kind == kind }.count + 1
        let node = DesignNode(kind: kind, name: "\(kind.rawValue) \(count)", x: rect.minX, y: rect.minY,
                              width: max(Self.minimumSize, rect.width), height: max(Self.minimumSize, rect.height))
        nodes.append(node)
        return node.id
    }

    public mutating func move(_ ids: Set<UUID>, by delta: CGSize) {
        for index in nodes.indices where ids.contains(nodes[index].id) && !nodes[index].isLocked {
            nodes[index].x += delta.width; nodes[index].y += delta.height
        }
    }

    public mutating func resize(_ id: UUID, handle: DesignHandle, to point: CGPoint) {
        guard let index = nodes.firstIndex(where: { $0.id == id }), !nodes[index].isLocked else { return }
        var minX = nodes[index].frame.minX, maxX = nodes[index].frame.maxX
        var minY = nodes[index].frame.minY, maxY = nodes[index].frame.maxY
        let size = Self.minimumSize
        switch handle {
        case .topLeft, .left, .bottomLeft: minX = min(point.x, maxX - size)
        case .topRight, .right, .bottomRight: maxX = max(point.x, minX + size)
        case .top, .bottom: break
        }
        switch handle {
        case .topLeft, .top, .topRight: minY = min(point.y, maxY - size)
        case .bottomLeft, .bottom, .bottomRight: maxY = max(point.y, minY + size)
        case .left, .right: break
        }
        nodes[index].x = minX; nodes[index].y = minY
        nodes[index].width = maxX - minX; nodes[index].height = maxY - minY
    }

    public mutating func remove(_ ids: Set<UUID>) { nodes.removeAll { ids.contains($0.id) } }

    @discardableResult
    public mutating func duplicate(_ ids: Set<UUID>, offset: Double = 16) -> [UUID] {
        var created: [UUID] = []
        for node in nodes where ids.contains(node.id) {
            var copy = node
            copy.id = UUID(); copy.x += offset; copy.y += offset; copy.name = node.name + " copy"
            created.append(copy.id)
            nodes.append(copy)
        }
        return created
    }

    public mutating func reorder(_ ids: Set<UUID>, toFront: Bool) {
        let picked = nodes.filter { ids.contains($0.id) }, rest = nodes.filter { !ids.contains($0.id) }
        nodes = toFront ? rest + picked : picked + rest
    }

    public mutating func step(_ id: UUID, forward: Bool) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        let target = index + (forward ? 1 : -1)
        guard nodes.indices.contains(target) else { return }
        nodes.swapAt(index, target)
    }

    public mutating func update(_ ids: Set<UUID>, _ change: (inout DesignNode) -> Void) {
        for index in nodes.indices where ids.contains(nodes[index].id) { change(&nodes[index]) }
    }

    /// Align selected nodes to the edges or centers of their shared bounds.
    public enum Alignment: Sendable { case left, centerX, right, top, centerY, bottom }
    public mutating func align(_ ids: Set<UUID>, _ alignment: Alignment) {
        guard ids.count > 1, let box = bounds(of: ids) else { return }
        for index in nodes.indices where ids.contains(nodes[index].id) && !nodes[index].isLocked {
            switch alignment {
            case .left: nodes[index].x = box.minX
            case .centerX: nodes[index].x = box.midX - nodes[index].width / 2
            case .right: nodes[index].x = box.maxX - nodes[index].width
            case .top: nodes[index].y = box.minY
            case .centerY: nodes[index].y = box.midY - nodes[index].height / 2
            case .bottom: nodes[index].y = box.maxY - nodes[index].height
            }
        }
    }
}
