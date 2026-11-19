import Foundation

public struct DesignImportOrigin: Codable, Hashable, Sendable {
    public var batchID: UUID
    public var key: String
}
public struct DesignImportBatch: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var baseline: DesignDocument
    public var files: [DesignImportFile]
    public init(id: UUID, name: String, baseline: DesignDocument, files: [DesignImportFile]) {
        self.id = id; self.name = name; self.baseline = baseline; self.files = files
    }
}
public struct DesignImportConflict: Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var reason: String
}
public struct DesignImportMerge: Sendable {
    public let conflicts: [DesignImportConflict]
    public let added: Int
    public let changed: Int
    public let removed: Int
    private let batch: DesignImportBatch
    private let current: DesignDocument
    private let targets: Set<UUID>
    private let proposed: [UUID: DesignNode]
    private let order: [UUID]
    private let proposedConnections: [DesignConnection]

    public init(batch: DesignImportBatch, current: DesignDocument, targets: Set<UUID>, proposal: DesignDocument) throws {
        self.batch = batch; self.current = current; self.targets = targets
        let old = batch.baseline.nodes.filter { targets.contains($0.id) }
        let content = Set(old.filter { $0.importOrigin?.key != "root" }.map(\.id))
        guard !old.isEmpty, let bounds = current.bounds(of: content.isEmpty ? targets : content) ?? batch.baseline.bounds(of: content.isEmpty ? targets : content), let incomingBounds = proposal.visibleBounds else {
            throw DesignToolError("Select imported layers to update.")
        }
        let keys = Dictionary(old.compactMap { node in node.importOrigin.map { ($0.key, node.id) } }, uniquingKeysWith: { first, _ in first })
        let generatedKeys = Self.keys(proposal.nodes)
        var idMap: [UUID: UUID] = [:], mapped: [UUID: DesignNode] = [:]
        for node in proposal.nodes {
            let key = generatedKeys[node.id]!
            let id = keys[key] ?? UUID()
            idMap[node.id] = id
            var copy = node; copy.id = id
            copy.x += bounds.minX - incomingBounds.minX; copy.y += bounds.minY - incomingBounds.minY
            if let previous = current.node(id) {
                copy.links = copy.links?.map { link in previous.links?.first { $0.kind == link.kind && $0.target == link.target && $0.line == link.line } ?? link }
            }
            copy.importOrigin = DesignImportOrigin(batchID: batch.id, key: key)
            mapped[id] = copy
        }
        let wrapper = old.first { $0.importOrigin?.key == "root" }?.id
        for node in proposal.nodes {
            guard let id = idMap[node.id] else { continue }
            mapped[id]?.layoutParentID = node.layoutParentID.flatMap { idMap[$0] } ?? current.node(id)?.layoutParentID ?? wrapper
        }
        var ordered = proposal.nodes.compactMap { idMap[$0.id] }
        for root in old where root.importOrigin?.key == "root" {
            if let live = current.node(root.id) { mapped[root.id] = live; ordered.insert(root.id, at: 0) }
        }
        proposed = mapped; order = ordered
        proposedConnections = (proposal.connections ?? []).compactMap { edge in
            guard let from = idMap[edge.from], let to = idMap[edge.to] else { return nil }
            var copy = edge; copy.id = UUID(); copy.from = from; copy.to = to; return copy
        }
        var conflicts: [DesignImportConflict] = []
        for original in old {
            guard let live = current.node(original.id) else {
                if mapped[original.id] != nil {
                    conflicts.append(DesignImportConflict(id: original.id, name: original.name, reason: "Deleted from the canvas; keep deleted unless restored below"))
                }
                continue
            }
            guard live != mapped[original.id] else { continue }
            if live != original || live.isLocked {
                conflicts.append(DesignImportConflict(id: live.id, name: live.name, reason: live.isLocked ? "Locked layer is preserved" : mapped[live.id] == nil ? "Removed in source; manually edited layer is preserved" : "Manual edits differ from the generated update"))
            }
        }
        self.conflicts = conflicts
        added = mapped.keys.filter { !targets.contains($0) }.count
        changed = mapped.values.filter { targets.contains($0.id) && current.node($0.id) != $0 }.count
        removed = old.filter { mapped[$0.id] == nil }.count
    }

    public func applying(useGenerated: Set<UUID> = []) throws -> (document: DesignDocument, baseline: DesignDocument) {
        var result = current, baseline = batch.baseline
        let preserve = Set(conflicts.map(\.id)).subtracting(useGenerated)
            .union(current.nodes.filter { $0.isLocked }.map(\.id))
        let deleting = targets.subtracting(proposed.keys).subtracting(preserve)
        // A manually added child keeps its containing frame alive.
        let parents = current.parents
        let protectedFrames = Set(current.nodes.filter { !targets.contains($0.id) }.compactMap { parents[$0.id] })
        let removed = deleting.subtracting(protectedFrames)
        result.nodes.removeAll { removed.contains($0.id) }
        baseline.nodes.removeAll { removed.contains($0.id) }
        for incoming in order.compactMap({ proposed[$0] }) where !preserve.contains(incoming.id) {
            if let index = result.nodes.firstIndex(where: { $0.id == incoming.id }) { result.nodes[index] = incoming }
            else { result.nodes.append(incoming) }
            if let index = baseline.nodes.firstIndex(where: { $0.id == incoming.id }) { baseline.nodes[index] = incoming }
            else { baseline.nodes.append(incoming) }
        }
        let baselineEdges = Set(batch.baseline.connections ?? [])
        result.connections = (result.connections ?? []).filter { edge in
            !removed.contains(edge.from) && !removed.contains(edge.to)
                && !(targets.contains(edge.from) && targets.contains(edge.to) && baselineEdges.contains(edge))
        }
        for edge in proposedConnections where result.node(edge.from) != nil && result.node(edge.to) != nil {
            if result.connections?.contains(where: { $0.from == edge.from && $0.to == edge.to }) != true { result.connections = (result.connections ?? []) + [edge] }
        }
        baseline.connections = (baseline.connections ?? []).filter { !targets.contains($0.from) && !targets.contains($0.to) } + proposedConnections
        guard result.nodes.count <= 500, (result.connections?.count ?? 0) <= 1_000 else { throw DesignToolError("The updated canvas would exceed 500 layers.") }
        result.normalize(); baseline.normalize()
        return (result, baseline)
    }

    public static func keys(_ nodes: [DesignNode]) -> [UUID: String] {
        var counts: [String: Int] = [:], result: [UUID: String] = [:]
        for node in nodes {
            let source = node.links?.first?.target ?? "layout"
            let base = source + "|" + node.kind.rawValue + "|" + node.name
            let index = counts[base, default: 0]; counts[base] = index + 1
            result[node.id] = base + "|" + String(index)
        }
        return result
    }
}
