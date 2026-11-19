import Foundation

/// A reusable arrangement contains view preferences, never editor buffers or browser history.
public struct WorkspaceViewPreset: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var primary: ProjectPanel
    public var secondary: ProjectPanel?
    public var tabs: [ProjectPanel]
    public var stacked: Bool
    public var fraction: Double
    public var showsInspector: Bool

    public init(id: UUID = UUID(), name: String, layout: ProjectLayout) {
        self.id = id; self.name = name; primary = layout.panel; secondary = layout.secondary
        tabs = layout.openTabs; stacked = layout.stacked; fraction = layout.splitFraction
        showsInspector = layout.showsInspector
    }

    public func applying(to original: ProjectLayout) -> ProjectLayout {
        var layout = original
        for tab in tabs { layout.openTab(tab) }
        layout.panel = primary
        layout.secondary = secondary == primary ? nil : secondary
        layout.stacked = stacked
        layout.splitFraction = fraction.isFinite ? min(0.8, max(0.2, fraction)) : 0.5
        layout.showsInspector = showsInspector
        layout.normalizeTabs()
        return layout
    }
}

public enum WorkspaceFocus: String, CaseIterable, Sendable, Identifiable {
    case design = "Design", debug = "Debug", services = "Services", review = "Review"
    public var id: String { rawValue }
    public var symbol: String {
        switch self { case .design: "square.on.circle"; case .debug: "ladybug"; case .services: "shippingbox"; case .review: "doc.text.magnifyingglass" }
    }
    public var preset: WorkspaceViewPreset {
        var layout = ProjectLayout()
        layout.showsInspector = false
        switch self {
        case .design: layout.panel = .design; layout.secondary = .code; layout.splitFraction = 0.65
        case .debug: layout.panel = .code; layout.secondary = .terminal; layout.stacked = true; layout.splitFraction = 0.65
        case .services: layout.panel = .containers; layout.secondary = .terminal; layout.splitFraction = 0.68
        case .review: layout.panel = .changes; layout.secondary = .code
        }
        return WorkspaceViewPreset(name: rawValue, layout: layout)
    }
}
