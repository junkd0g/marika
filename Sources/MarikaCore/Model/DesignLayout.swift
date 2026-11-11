import Foundation

public enum DesignLayoutDirection: String, CaseIterable, Sendable { case horizontal, vertical }

extension DesignDocument {
    /// A deterministic layered layout. Cycles are broken for ordering, never deleted.
    /// Frames move with their contents; locked subtrees remain fixed.
    public mutating func tidyLayout(selection: Set<UUID> = [], direction: DesignLayoutDirection = .horizontal) {
        let parentMap = parents
        let originalIDs = Set(nodes.map(\.id))
        let visible = nodes.filter { !$0.isHidden }
        func descendants(_ id: UUID) -> Set<UUID> {
            Set(nodes.filter { node in
                var current: UUID? = node.id
                while let value = current { if value == id { return true }; current = parentMap[value] }
                return false
            }.map(\.id))
        }
        func fixed(_ id: UUID) -> Bool { nodes.contains { descendants(id).contains($0.id) && $0.isLocked } }
        func rootOf(_ id: UUID, in units: Set<UUID>) -> UUID? {
            var current: UUID? = id
            while let value = current { if units.contains(value) { return value }; current = parentMap[value] }
            return nil
        }
        func move(_ id: UUID, to origin: CGPoint) {
            guard let node = node(id), !fixed(id) else { return }
            let delta = CGSize(width: origin.x - node.x, height: origin.y - node.y)
            self.move(descendants(id), by: delta)
        }
        func fitFrame(_ id: UUID) {
            guard let index = nodes.firstIndex(where: { $0.id == id }), !fixed(id), nodes[index].kind == .frame,
                  let box = bounds(of: descendants(id).subtracting([id])) else { return }
            nodes[index].x = box.minX - 32; nodes[index].y = box.minY - 40
            nodes[index].width = box.width + 64; nodes[index].height = box.height + 72
        }
        func arrange(_ ids: [UUID]) {
            guard !ids.isEmpty else { return }
            for id in ids where node(id)?.kind == .frame && !fixed(id) {
                arrange(visible.filter { parentMap[$0.id] == id }.map(\.id)); fitFrame(id)
            }
            guard ids.count > 1 else { return }
            let units = Set(ids)
            var incoming: [UUID: Set<UUID>] = [:], outgoing: [UUID: Set<UUID>] = [:]
            for edge in connections ?? [] {
                if let a = rootOf(edge.from, in: units), let b = rootOf(edge.to, in: units), a != b {
                    outgoing[a, default: []].insert(b); incoming[b, default: []].insert(a)
                }
            }
            let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
            var remaining = units, rank: [UUID: Int] = [:]
            while !remaining.isEmpty {
                let ready = remaining.filter { (incoming[$0] ?? []).intersection(remaining).isEmpty }
                let next = (ready.isEmpty ? Array(remaining) : Array(ready)).sorted { order[$0, default: 0] < order[$1, default: 0] }.first!
                rank[next] = (incoming[next] ?? []).compactMap { rank[$0] }.max().map { $0 + 1 } ?? 0
                remaining.remove(next)
            }
            var layers = Dictionary(grouping: ids) { rank[$0, default: 0] }
            var positions = order.mapValues(Double.init)
            for _ in 0..<3 {
                for level in layers.keys.sorted() {
                    layers[level]?.sort { a, b in
                        func average(_ id: UUID) -> Double {
                            let values = (incoming[id] ?? []).compactMap { positions[$0] }
                            return values.isEmpty ? positions[id, default: 0] : values.reduce(0, +) / Double(values.count)
                        }
                        let x = average(a), y = average(b)
                        return x == y ? order[a, default: 0] < order[b, default: 0] : x < y
                    }
                    for (index, id) in (layers[level] ?? []).enumerated() { positions[id] = Double(index) }
                }
            }
            guard let box = bounds(of: units) else { return }
            var across = direction == .horizontal ? box.minX : box.minY
            let parent = parentMap[ids[0]]
            var placed = nodes.filter {
                !$0.isHidden && parentMap[$0.id] == parent && (!units.contains($0.id) || fixed($0.id))
            }.map { $0.bounds.insetBy(dx: -20, dy: -20) }
            for level in layers.keys.sorted() {
                let layer = layers[level] ?? []
                let width = layer.compactMap { node($0) }.map { direction == .horizontal ? $0.width : $0.height }.max() ?? 0
                var along = direction == .horizontal ? box.minY : box.minX
                for id in layer {
                    guard let current = node(id), !fixed(id) else { continue }
                    var origin = direction == .horizontal ? CGPoint(x: across, y: along) : CGPoint(x: along, y: across)
                    var candidate = CGRect(origin: origin, size: current.frame.size)
                    var attempts = 0
                    while placed.contains(where: { $0.intersects(candidate) }), attempts < 100 {
                        along += direction == .horizontal ? current.height + 48 : current.width + 48
                        origin = direction == .horizontal ? CGPoint(x: across, y: along) : CGPoint(x: along, y: across)
                        candidate.origin = origin; attempts += 1
                    }
                    move(id, to: origin); placed.append(candidate.insetBy(dx: -16, dy: -16))
                    along += direction == .horizontal ? current.height + 48 : current.width + 48
                }
                across += width + 100
            }
        }
        let picked = selection.isEmpty ? Set(visible.map(\.id)) : selection.intersection(originalIDs)
        let roots = visible.filter { node in
            guard picked.contains(node.id) else { return false }
            var parent = parentMap[node.id]
            while let id = parent { if picked.contains(id) { return false }; parent = parentMap[id] }
            return true
        }
        let groups = Dictionary(grouping: roots) { parentMap[$0.id] }
        for (parent, members) in groups { arrange(members.map(\.id)); if let parent { fitFrame(parent) } }
        normalize()
    }
}
