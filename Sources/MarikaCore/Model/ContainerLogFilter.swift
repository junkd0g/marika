import Foundation

public enum ContainerLogSeverityFilter: String, CaseIterable, Sendable {
    case all = "All", warningsAndErrors = "Warnings + errors", errors = "Errors"

    public func includes(_ level: ContainerLogLevel) -> Bool {
        switch self {
        case .all: true
        case .warningsAndErrors: level == .warning || level == .error
        case .errors: level == .error
        }
    }
}

/// Accounts for sub-millisecond precision differences in server timestamps.
public struct ContainerLogWindow: Sendable {
    public let start: Date
    public let end: Date
    public init(start: Date, end: Date) { self.start = start; self.end = end }
    public func contains(_ timestamp: Date) -> Bool {
        timestamp >= start.addingTimeInterval(-0.001) && timestamp <= end.addingTimeInterval(0.001)
    }
}

public struct ContainerLogFilter: Sendable {
    public var text: String
    public var severity: ContainerLogSeverityFilter
    public var window: ContainerLogWindow
    public init(text: String, severity: ContainerLogSeverityFilter, start: Date, end: Date) {
        self.text = text; self.severity = severity; window = ContainerLogWindow(start: start, end: end)
    }
    public func apply(to entries: [ContainerLogEntry]) -> [ContainerLogEntry] {
        entries.filter { entry in
            severity.includes(entry.level) && window.contains(entry.timestamp)
                && (text.isEmpty || (entry.message + " " + entry.source).localizedCaseInsensitiveContains(text))
        }
    }
}
