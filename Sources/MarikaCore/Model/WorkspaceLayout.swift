import Foundation

public enum ProjectPanel: String, Codable, CaseIterable, Sendable {
    case conversation = "Conversation", code = "Code", browser = "Browser", agents = "Agents", stats = "Stats", pipelines = "Pipelines", api = "API", changes = "Changes", terminal = "Terminal"
    public var title: String { self == .conversation ? "Chat" : rawValue }
    public var shortcut: String {
        switch self { case .conversation: "1"; case .code: "2"; case .browser: "3"; case .agents: "4"; case .stats: "5"; case .pipelines: "6"; case .api: "7"; case .changes: "8"; case .terminal: "9" }
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
    public var panel: ProjectPanel = .conversation
    public var secondary: ProjectPanel?
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
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case panel, secondary, stacked, splitFraction, showsInspector, showsNavigator, navigatorWidth
        case files, selectedFile, browserURLs, browserIndex, browserViewport
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        panel = try c.decodeIfPresent(ProjectPanel.self, forKey: .panel) ?? .conversation
        secondary = try c.decodeIfPresent(ProjectPanel.self, forKey: .secondary)
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
        if secondary == panel { secondary = nil }
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
