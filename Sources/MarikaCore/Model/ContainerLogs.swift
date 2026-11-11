import CryptoKit
import Foundation

public struct ContainerLogConnection: Codable, Hashable, Sendable {
    public var endpoint: String
    public var username: String
    public var tenant: String
    public var grafanaURL: String
    public init(endpoint: String = "", username: String = "", tenant: String = "", grafanaURL: String = "") {
        self.endpoint = endpoint; self.username = username; self.tenant = tenant; self.grafanaURL = grafanaURL
    }
    public func credentialAccount(projectID: UUID) -> String {
        "container-loki-" + projectID.uuidString + "-" + SHA256.hash(data: Data(endpoint.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ContainerLogLevel: String, CaseIterable, Sendable {
    case trace, debug, info, warning, error, unknown
    public static func detect(_ text: String) -> Self {
        if let data = text.data(using: .utf8), let json = try? JSONValue(parsing: data),
           let level = json["level"]?.string ?? json["severity"]?.string ?? json["severity_text"]?.string {
            switch level.lowercased() {
            case "fatal", "critical", "error", "err": return .error
            case "warn", "warning": return .warning
            case "info", "information": return .info
            case "debug": return .debug
            case "trace": return .trace
            default: break
            }
        }
        let prefix = String(text.prefix(100)).lowercased()
        for (pattern, level) in [(#"\b(error|fatal|critical|panic)\b"#, Self.error), (#"\b(warn|warning)\b"#, .warning), (#"\binfo\b"#, .info), (#"\bdebug\b"#, .debug), (#"\btrace\b"#, .trace)] {
            if prefix.range(of: pattern, options: .regularExpression) != nil { return level }
        }
        return .unknown
    }
}

public struct ContainerLogEntry: Identifiable, Sendable, Hashable {
    public var id: String
    public var timestamp: Date
    public var source: String
    public var message: String
    public var level: ContainerLogLevel
    public init(id: String, timestamp: Date, source: String, message: String, level: ContainerLogLevel? = nil) {
        self.id = id; self.timestamp = timestamp; self.source = source; self.message = message; self.level = level ?? ContainerLogLevel.detect(message)
    }
    public var fields: [(String, String)] {
        guard let json = try? JSONValue(parsing: Data(message.utf8)), let object = json.object else { return [] }
        return object.keys.sorted().map { key in
            let value = object[key]!
            return (key, value.string ?? String(decoding: (try? value.serialized()) ?? Data(), as: UTF8.self))
        }
    }
}

public struct ContainerLogBuffer: Sendable {
    public private(set) var entries: [ContainerLogEntry] = []
    public private(set) var dropped = 0
    public let limit: Int
    private var pending: [String: Data] = [:]
    private var serial = 0
    public init(limit: Int = 2_000) { self.limit = max(1, limit) }
    public mutating func clear() { entries = []; pending = [:]; dropped = 0 }
    public mutating func append(_ data: Data, source: String, now: Date = Date(), flush: Bool = false) {
        var bytes = pending.removeValue(forKey: source) ?? Data()
        bytes.append(data)
        while let newline = bytes.firstIndex(of: 10) {
            let line = bytes[..<newline]
            bytes.removeSubrange(...newline)
            insertLine(String(decoding: line, as: UTF8.self), source: source, now: now)
        }
        if flush && !bytes.isEmpty { insertLine(String(decoding: bytes, as: UTF8.self), source: source, now: now); bytes.removeAll() }
        if bytes.count > 256_000 { insertLine(String(decoding: bytes.prefix(256_000), as: UTF8.self) + " [line truncated]", source: source, now: now); bytes.removeAll() }
        if !bytes.isEmpty { pending[source] = bytes }
        trim()
    }
    public mutating func merge(_ incoming: [ContainerLogEntry]) {
        var known = Set(entries.map(\.id))
        entries.append(contentsOf: incoming.filter { known.insert($0.id).inserted })
        trim()
    }
    private mutating func insertLine(_ raw: String, source: String, now: Date) {
        let raw = raw.trimmingCharacters(in: .newlines)
        guard !raw.isEmpty else { return }
        var text = raw, name = source
        if (text.hasPrefix("[pod/") || text.hasPrefix("[container/")), let end = text.firstIndex(of: "]") {
            name = String(text[text.index(after: text.startIndex)..<end]); text = String(text[text.index(after: end)...]).trimmingCharacters(in: .whitespaces)
        }
        var timestamp = now
        if let space = text.firstIndex(of: " "), let date = Self.date(String(text[..<space])) {
            timestamp = date; text = String(text[text.index(after: space)...])
        }
        serial += 1
        let message = text.count > 32_000 ? String(text.prefix(32_000)) + " [line truncated]" : text
        entries.append(ContainerLogEntry(id: "runtime:\(serial)", timestamp: timestamp, source: name, message: message))
    }
    private mutating func trim() {
        entries.sort { $0.timestamp < $1.timestamp }
        if entries.count > limit { dropped += entries.count - limit; entries.removeFirst(entries.count - limit) }
    }
    public static func date(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}

public struct ContainerLogBucket: Identifiable, Sendable {
    public var id: Int
    public var start: Date
    public var count: Int
    public var errors: Int
}
public enum ContainerLogChart {
    public static func buckets(_ entries: [ContainerLogEntry], start: Date, end: Date, count: Int = 40) -> [ContainerLogBucket] {
        let count = max(1, count), seconds = max(1, end.timeIntervalSince(start))
        var buckets = (0..<count).map { ContainerLogBucket(id: $0, start: start.addingTimeInterval(Double($0) * seconds / Double(count)), count: 0, errors: 0) }
        let window = ContainerLogWindow(start: start, end: end)
        for entry in entries where window.contains(entry.timestamp) {
            let index = max(0, min(count - 1, Int(entry.timestamp.timeIntervalSince(start) / seconds * Double(count))))
            buckets[index].count += 1
            if entry.level == .error { buckets[index].errors += 1 }
        }
        return buckets
    }
}
