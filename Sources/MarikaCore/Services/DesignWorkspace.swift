import Foundation
import Observation

/// One synchronous document and undo history shared by the project's chat and canvas views.
@MainActor @Observable
public final class DesignWorkspace {
    public private(set) var document: DesignDocument
    public private(set) var externalRevision = 0
    private var previous: [DesignDocument] = []
    private var following: [DesignDocument] = []
    @ObservationIgnored public var onChange: ((DesignDocument) -> Void)?
    @ObservationIgnored private var lastKey: String?
    @ObservationIgnored private var lastEdit = Date.distantPast
    @ObservationIgnored private var interaction: String?

    public init(document: DesignDocument = DesignDocument()) {
        var normalized = document; normalized.normalize()
        self.document = normalized
    }

    public var canUndo: Bool { !previous.isEmpty }
    public var canRedo: Bool { !following.isEmpty }

    public func edit(coalescing key: String? = nil, at date: Date = Date(), _ change: (inout DesignDocument) -> Void) {
        apply(key: key, date: date, interval: 1, change)
    }

    public func beginInteraction() { interaction = UUID().uuidString; lastKey = nil }
    public func endInteraction() { interaction = nil; lastKey = nil }
    public func updateInteraction(_ change: (inout DesignDocument) -> Void) {
        apply(key: interaction, date: Date(), interval: .infinity, change)
    }

    private func apply(key: String?, date: Date, interval: TimeInterval, _ change: (inout DesignDocument) -> Void) {
        var next = document
        change(&next); next.normalize()
        guard next != document else { return }
        if key == nil || key != lastKey || date.timeIntervalSince(lastEdit) > interval {
            previous.append(document)
            if previous.count > 100 { previous.removeFirst() }
        }
        following.removeAll()
        lastKey = key; lastEdit = date
        document = next
        onChange?(document)
    }

    public func receive(_ incoming: DesignDocument) {
        let before = document
        endInteraction()
        edit { $0 = incoming }
        if document != before { externalRevision += 1 }
    }

    public func undo() {
        guard let next = previous.popLast() else { return }
        endInteraction(); following.append(document); document = next; onChange?(document)
    }

    public func redo() {
        guard let next = following.popLast() else { return }
        endInteraction(); previous.append(document); document = next; onChange?(document)
    }
}

public struct DesignExportPlan: Sendable {
    public var nodes: [DesignNode]
    public var connections: [DesignConnection]
    public var bounds: CGRect
    public var scale: Double

    public init(document: DesignDocument, selection: Set<UUID> = []) throws {
        let picked = document.withChildren(selection)
        nodes = document.nodes.filter { !$0.isHidden && (picked.isEmpty || picked.contains($0.id)) }
        guard let first = nodes.first else { throw DesignToolError("There are no visible shapes to export.") }
        bounds = nodes.dropFirst().reduce(first.visualBounds) { $0.union($1.visualBounds) }.insetBy(dx: -16, dy: -16)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            throw DesignToolError("The canvas contains invalid dimensions.")
        }
        let ids = Set(nodes.map(\.id))
        connections = (document.connections ?? []).filter { ids.contains($0.from) && ids.contains($0.to) }
        for edge in connections {
            for point in edge.route(in: nodes) ?? [] { bounds = bounds.union(CGRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32)) }
            if !edge.label.isEmpty, let center = edge.labelPoint(in: nodes) {
                let halfWidth = Double(edge.label.count) * 7 + 10
                bounds = bounds.union(CGRect(x: center.x - halfWidth, y: center.y - 16, width: halfWidth * 2, height: 32))
            }
        }
        // Bound both dimensions and total pixels before allocating an image.
        scale = min(2, 8192 / max(bounds.width, bounds.height), sqrt(24_000_000 / (bounds.width * bounds.height)))
    }
}
