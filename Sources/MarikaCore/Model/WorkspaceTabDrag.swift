import Foundation

/// A project view can be dragged from either its tab or the Views shortcuts.
public struct WorkspaceTabDrag: Codable, Equatable, Sendable {
    public let projectID: UUID
    public let panel: ProjectPanel

    public init(projectID: UUID, panel: ProjectPanel) {
        self.projectID = projectID
        self.panel = panel
    }
}

public enum ProjectSplitEdge: String, CaseIterable, Sendable {
    case left, right, top, bottom

    public var stacked: Bool { self == .top || self == .bottom }
    public var leading: Bool { self == .left || self == .top }

    /// The center remains neutral so dragging over content does not unexpectedly split it.
    public static func target(x: Double, y: Double, width: Double, height: Double) -> Self? {
        guard width > 0, height > 0, x >= 0, y >= 0, x <= width, y <= height else { return nil }
        let distances: [(Self, Double)] = [(.left, x / width), (.right, (width - x) / width),
                                          (.top, y / height), (.bottom, (height - y) / height)]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 <= 0.25 else { return nil }
        return nearest.0
    }
}
