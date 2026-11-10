import Foundation

public enum ProjectPanel: String, Codable, CaseIterable, Sendable {
    case conversation = "Conversation", code = "Code", browser = "Browser", agents = "Agents", stats = "Stats", pipelines = "Pipelines", api = "API", changes = "Changes", terminal = "Terminal", research = "Research", design = "Design"
    public var title: String { self == .conversation ? "Chat" : rawValue }
    public var shortcut: String {
        switch self { case .conversation: "1"; case .code: "2"; case .browser: "3"; case .agents: "4"; case .stats: "5"; case .pipelines: "6"; case .api: "7"; case .changes: "8"; case .terminal: "9"; case .research: "0"; case .design: "g" }
    }
}

public enum MarkdownPresentation: String, Codable, CaseIterable, Sendable {
    case preview = "Preview", source = "Edit", split = "Split"
}

public struct EditorFileState: Codable, Equatable, Hashable, Sendable {
    public var path: String
    public var draft: String?
    public var baseText: String?
    public var line: Int
    public var column: Int
    public var markdownPresentation: MarkdownPresentation?
    public init(path: String, draft: String? = nil, baseText: String? = nil, line: Int = 1, column: Int = 1, markdownPresentation: MarkdownPresentation? = nil) {
        self.path = path; self.draft = draft; self.baseText = baseText; self.line = line; self.column = column
        self.markdownPresentation = markdownPresentation
    }
}

public struct ProjectLayout: Codable, Equatable, Hashable, Sendable {
    public var panel: ProjectPanel = .conversation { didSet { includeTab(panel) } }
    public var secondary: ProjectPanel? { didSet { if let secondary { includeTab(secondary) } } }
    public private(set) var openTabs: [ProjectPanel] = [.conversation]
    public var stacked = false
    public var splitFraction = 0.5
    public var showsInspector = true
    public var showsNavigator = true
    public var navigatorWidth = 220.0
    public var files: [EditorFileState] = []
    public var selectedFile: String?
    public var browserURLs: [String] = []
    public var browserIndex = 0
    public var browserViewport = "Desktop"
    public var browserLibrary = BrowserLibrary()
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case panel, secondary, openTabs, stacked, splitFraction, showsInspector, showsNavigator, navigatorWidth
        case files, selectedFile, browserURLs, browserIndex, browserViewport, browserLibrary
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        panel = try c.decodeIfPresent(ProjectPanel.self, forKey: .panel) ?? .conversation
        secondary = try c.decodeIfPresent(ProjectPanel.self, forKey: .secondary)
        openTabs = try c.decodeIfPresent([ProjectPanel].self, forKey: .openTabs) ?? [.conversation]
        stacked = try c.decodeIfPresent(Bool.self, forKey: .stacked) ?? false
        splitFraction = min(0.8, max(0.2, try c.decodeIfPresent(Double.self, forKey: .splitFraction) ?? 0.5))
        showsInspector = try c.decodeIfPresent(Bool.self, forKey: .showsInspector) ?? true
        showsNavigator = try c.decodeIfPresent(Bool.self, forKey: .showsNavigator) ?? true
        navigatorWidth = min(280, max(170, try c.decodeIfPresent(Double.self, forKey: .navigatorWidth) ?? 220))
        files = try c.decodeIfPresent([EditorFileState].self, forKey: .files) ?? []
        selectedFile = try c.decodeIfPresent(String.self, forKey: .selectedFile)
        browserURLs = try c.decodeIfPresent([String].self, forKey: .browserURLs) ?? []
        browserIndex = try c.decodeIfPresent(Int.self, forKey: .browserIndex) ?? 0
        browserViewport = try c.decodeIfPresent(String.self, forKey: .browserViewport) ?? "Desktop"
        browserLibrary = try c.decodeIfPresent(BrowserLibrary.self, forKey: .browserLibrary) ?? BrowserLibrary()
        if secondary == panel { secondary = nil }
        normalizeTabs()
    }

    public mutating func normalizeTabs() {
        var seen: Set<ProjectPanel> = [.conversation]
        openTabs = [.conversation] + openTabs.filter { seen.insert($0).inserted }
        includeTab(panel)
        if let secondary { includeTab(secondary) }
    }

    public mutating func openTab(_ tab: ProjectPanel) {
        let previous = panel
        let swapping = secondary == tab && tab != previous
        panel = tab
        if swapping { secondary = previous }
        if secondary == panel { secondary = nil }
    }

    @discardableResult
    public mutating func closeTab(_ tab: ProjectPanel) -> Bool {
        guard tab != .conversation, let index = openTabs.firstIndex(of: tab) else { return false }
        openTabs.remove(at: index)
        if secondary == tab { secondary = nil }
        if panel == tab {
            let next = secondary ?? openTabs[max(0, index - 1)]
            secondary = nil
            panel = next
        }
        return true
    }

    public mutating func closeOtherTabs(keeping tab: ProjectPanel) {
        secondary = nil
        openTabs = tab == .conversation ? [.conversation] : [.conversation, tab]
        panel = tab
    }

    @discardableResult
    public mutating func moveTab(_ tab: ProjectPanel, offset: Int) -> Bool {
        guard tab != .conversation, let index = openTabs.firstIndex(of: tab),
              index + offset > 0, openTabs.indices.contains(index + offset) else { return false }
        openTabs.remove(at: index)
        openTabs.insert(tab, at: index + offset)
        return true
    }

    public func adjacentTab(_ offset: Int) -> ProjectPanel {
        let index = openTabs.firstIndex(of: panel) ?? 0
        return openTabs[(index + offset % openTabs.count + openTabs.count) % openTabs.count]
    }

    /// Put the dragged view at an edge, retaining the other visible view when possible.
    @discardableResult
    public mutating func splitTab(_ tab: ProjectPanel, at edge: ProjectSplitEdge) -> Bool {
        let other = panel == tab ? secondary ?? openTabs.last(where: { $0 != tab }) : panel
        guard let other, other != tab else { return false }
        secondary = nil
        panel = edge.leading ? tab : other
        secondary = edge.leading ? other : tab
        stacked = edge.stacked
        splitFraction = 0.5
        return true
    }

    private mutating func includeTab(_ tab: ProjectPanel) {
        if !openTabs.contains(tab) { openTabs.append(tab) }
    }
}

public struct PreviewConfiguration: Codable, Equatable, Hashable, Sendable {
    public var command: String
    public var address: String
    public init(command: String, address: String) { self.command = command; self.address = address }
}

public struct AgentWorkspace: Codable, Equatable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case ready, applied, reviewed, discarded }
    public var rootPath: String
    public var workingPath: String
    public var branch: String
    public var baseCommit: String
    public var status: Status = .ready
    public var acceptedChanges: Int?
    public var rejectedChanges: Int?
    public init(rootPath: String, workingPath: String, branch: String, baseCommit: String) {
        self.rootPath = rootPath; self.workingPath = workingPath; self.branch = branch; self.baseCommit = baseCommit
    }
}
