import Foundation

public enum DesignPort: String, Codable, CaseIterable, Sendable {
    case auto, left, right, top, bottom
    public var opposite: DesignPort { switch self { case .left: .right; case .right: .left; case .top: .bottom; case .bottom: .top; case .auto: .auto } }
    public func anchor(in box: CGRect) -> CGPoint {
        switch self {
        case .left: CGPoint(x: box.minX, y: box.midY)
        case .right: CGPoint(x: box.maxX, y: box.midY)
        case .top: CGPoint(x: box.midX, y: box.minY)
        case .bottom: CGPoint(x: box.midX, y: box.maxY)
        case .auto: CGPoint(x: box.midX, y: box.midY)
        }
    }
    public func offset(_ point: CGPoint, by distance: Double) -> CGPoint {
        switch self {
        case .left: CGPoint(x: point.x - distance, y: point.y)
        case .right: CGPoint(x: point.x + distance, y: point.y)
        case .top: CGPoint(x: point.x, y: point.y - distance)
        case .bottom: CGPoint(x: point.x, y: point.y + distance)
        case .auto: point
        }
    }
}

public enum DesignFlow: String, Codable, CaseIterable, Sendable {
    case request, event, data
    public var title: String { switch self { case .request: "HTTP / RPC"; case .event: "Event"; case .data: "Data flow" } }
    public var color: DesignColor { switch self { case .request: DesignColor(0.5, 0.5, 0.5); case .event: DesignColor(0.72, 0.43, 0.15); case .data: DesignColor(0.2, 0.48, 0.7) } }
    public var dash: [Double] { switch self { case .request: []; case .event: [8, 5]; case .data: [2, 4] } }
}

extension DesignConnection {
    public var flow: DesignFlow { style ?? .request }
    public var labelFraction: Double { min(0.9, max(0.1, labelPosition ?? 0.5)) }
    public mutating func reverse() {
        (from, to) = (to, from)
        (fromPort, toPort) = (toPort, fromPort)
        if labelPosition != nil { labelPosition = 1 - labelFraction }
    }
    public func labelPoint(in nodes: [DesignNode]) -> CGPoint? { route(in: nodes).map { Self.point(on: $0, fraction: labelFraction) } }
    public static func point(on route: [CGPoint], fraction: Double) -> CGPoint {
        let segments = zip(route, route.dropFirst()).map { ($0, $1, hypot($1.x - $0.x, $1.y - $0.y)) }
        var remaining = segments.reduce(0) { $0 + $1.2 } * min(1, max(0, fraction))
        for (a, b, length) in segments where length > 0 {
            if remaining <= length { return CGPoint(x: a.x + (b.x - a.x) * remaining / length, y: a.y + (b.y - a.y) * remaining / length) }
            remaining -= length
        }
        return route.last ?? .zero
    }
    public static func fraction(on route: [CGPoint], nearest point: CGPoint) -> Double {
        var walked = 0.0, bestDistance = Double.infinity, bestAlong = 0.0
        for (a, b) in zip(route, route.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y, length = hypot(dx, dy)
            guard length > 0 else { continue }
            let t = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / (length * length)))
            let distance = hypot(point.x - a.x - t * dx, point.y - a.y - t * dy)
            if distance < bestDistance { bestDistance = distance; bestAlong = walked + t * length }
            walked += length
        }
        return walked > 0 ? min(0.9, max(0.1, bestAlong / walked)) : 0.5
    }
}

/// Bounded orthogonal routing. Fast unobstructed routes retain their familiar shape; a
/// visibility grid routes around nearby boxes when the straight elbow would cross them.
enum DesignRouter {
    static func route(_ edge: DesignConnection, nodes: [DesignNode]) -> [CGPoint]? {
        guard edge.from != edge.to, let source = nodes.first(where: { $0.id == edge.from && !$0.isHidden }),
              let target = nodes.first(where: { $0.id == edge.to && !$0.isHidden }) else { return nil }
        let a = source.bounds, b = target.bounds
        let dx = b.midX - a.midX, dy = b.midY - a.midY
        let automatic: DesignPort = abs(dx) >= abs(dy) ? (dx >= 0 ? .right : .left) : (dy >= 0 ? .bottom : .top)
        let from = edge.fromPort.flatMap { $0 == .auto ? nil : $0 } ?? automatic
        let to = edge.toPort.flatMap { $0 == .auto ? nil : $0 } ?? automatic.opposite
        let start = from.anchor(in: a), end = to.anchor(in: b)
        let middle = abs(dx) >= abs(dy) ? [CGPoint(x: (start.x + end.x) / 2, y: start.y), CGPoint(x: (start.x + end.x) / 2, y: end.y)]
            : [CGPoint(x: start.x, y: (start.y + end.y) / 2), CGPoint(x: end.x, y: (start.y + end.y) / 2)]
        let direct = [start] + middle + [end]
        let others = nodes.filter { !$0.isHidden && !$0.isLinear && $0.kind != .frame && $0.id != source.id && $0.id != target.id }
            .map { $0.bounds.insetBy(dx: -12, dy: -12) }
        if (edge.fromPort == nil || edge.fromPort == .auto), (edge.toPort == nil || edge.toPort == .auto),
           edge.avoidsObstacles == false || clear(direct, obstacles: others) { return direct }
        let s = from.offset(start, by: 20), t = to.offset(end, by: 20)
        let corridor = CGRect(x: min(s.x, t.x), y: min(s.y, t.y), width: abs(s.x - t.x), height: abs(s.y - t.y))
        let nearby = edge.avoidsObstacles == false ? [] : Array(others.sorted { distance($0, corridor) < distance($1, corridor) }.prefix(48))
        let boxes = Array(nearby) + [a.insetBy(dx: -6, dy: -6), b.insetBy(dx: -6, dy: -6)]
        if let path = grid(from: s, to: t, boxes: boxes) { return simplify([start] + path + [end]) }
        return direct
    }
    private static func distance(_ a: CGRect, _ b: CGRect) -> Double {
        hypot(max(0, max(a.minX - b.maxX, b.minX - a.maxX)), max(0, max(a.minY - b.maxY, b.minY - a.maxY)))
    }
    private static func inside(_ point: CGPoint, _ box: CGRect) -> Bool {
        point.x > box.minX + 0.01 && point.x < box.maxX - 0.01 && point.y > box.minY + 0.01 && point.y < box.maxY - 0.01
    }
    private static func clear(_ path: [CGPoint], obstacles: [CGRect]) -> Bool {
        for (a, b) in zip(path, path.dropFirst()) {
            for box in obstacles {
                if abs(a.x - b.x) < 0.01, a.x > box.minX, a.x < box.maxX,
                   max(a.y, b.y) > box.minY, min(a.y, b.y) < box.maxY { return false }
                if abs(a.y - b.y) < 0.01, a.y > box.minY, a.y < box.maxY,
                   max(a.x, b.x) > box.minX, min(a.x, b.x) < box.maxX { return false }
            }
        }
        return true
    }
    private static func grid(from start: CGPoint, to end: CGPoint, boxes: [CGRect]) -> [CGPoint]? {
        let xs = Array(Set([start.x, end.x] + boxes.flatMap { [$0.minX, $0.maxX] })).sorted()
        let ys = Array(Set([start.y, end.y] + boxes.flatMap { [$0.minY, $0.maxY] })).sorted()
        let width = xs.count, count = width * ys.count
        guard count <= 12_000, let sx = xs.firstIndex(of: start.x), let sy = ys.firstIndex(of: start.y),
              let tx = xs.firstIndex(of: end.x), let ty = ys.firstIndex(of: end.y) else { return nil }
        func point(_ index: Int) -> CGPoint { CGPoint(x: xs[index % width], y: ys[index / width]) }
        let blocked = (0..<count).map { index in boxes.contains { inside(point(index), $0) } }
        let first = sy * width + sx, last = ty * width + tx
        var scores = Array(repeating: Double.infinity, count: count), previous = Array(repeating: -1, count: count)
        var closed = Array(repeating: false, count: count), heap = Heap()
        scores[first] = 0; heap.push(first, priority: 0)
        while let current = heap.pop() {
            if closed[current] { continue }; closed[current] = true
            if current == last {
                var path = [end], cursor = last
                while cursor != first { cursor = previous[cursor]; guard cursor >= 0 else { return nil }; path.append(point(cursor)) }
                return path.reversed()
            }
            let x = current % width, y = current / width
            let neighbors = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            for (nx, ny) in neighbors where nx >= 0 && ny >= 0 && nx < width && ny < ys.count {
                let next = ny * width + nx
                guard !closed[next], !blocked[next] else { continue }
                let p = point(current), q = point(next)
                let middle = CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
                guard !boxes.contains(where: { inside(middle, $0) }) else { continue }
                let bend = previous[current] >= 0 && ((previous[current] % width == x) != (nx == x)) ? 12.0 : 0
                let score = scores[current] + abs(q.x - p.x) + abs(q.y - p.y) + bend
                if score < scores[next] {
                    scores[next] = score; previous[next] = current
                    heap.push(next, priority: score + abs(q.x - end.x) + abs(q.y - end.y))
                }
            }
        }
        return nil
    }
    private static func simplify(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for point in points {
            if result.last == point { continue }
            if result.count >= 2 {
                let a = result[result.count - 2], b = result[result.count - 1]
                if (a.x == b.x && b.x == point.x) || (a.y == b.y && b.y == point.y) { result.removeLast() }
            }
            result.append(point)
        }
        return result
    }
    private struct Heap {
        var items: [(Int, Double)] = []
        mutating func push(_ value: Int, priority: Double) {
            items.append((value, priority)); var i = items.count - 1
            while i > 0 { let p = (i - 1) / 2; if items[p].1 <= items[i].1 { break }; items.swapAt(p, i); i = p }
        }
        mutating func pop() -> Int? {
            guard !items.isEmpty else { return nil }
            let result = items[0].0, last = items.removeLast()
            if !items.isEmpty {
                items[0] = last; var i = 0
                while i * 2 + 1 < items.count {
                    var child = i * 2 + 1
                    if child + 1 < items.count && items[child + 1].1 < items[child].1 { child += 1 }
                    if items[i].1 <= items[child].1 { break }; items.swapAt(i, child); i = child
                }
            }
            return result
        }
    }
}
