import Foundation

public struct MCPServerConfiguration: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public var name: String
    public var configuration: JSONValue
    public var enabled: Bool { configuration["disabled"]?.bool != true }
    public var transport: String { configuration["command"] != nil ? "stdio" : configuration["type"]?.string == "sse" ? "sse" : "http" }
    public var summary: String {
        if let command = configuration["command"]?.string { return command }
        guard var url = URLComponents(string: configuration["url"]?.string ?? "") else { return "Remote MCP server" }
        url.user = nil; url.password = nil; url.query = nil; url.fragment = nil
        return url.string ?? "Remote MCP server"
    }
    public init(name: String, configuration: JSONValue) { self.name = name; self.configuration = configuration }
}

public enum MCPConfigurationEditor {
    public static func servers(in json: String) throws -> [MCPServerConfiguration] {
        try ProjectMCP.servers(json).sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { MCPServerConfiguration(name: $0.key, configuration: $0.value) }
    }
    public static func save(_ server: MCPServerConfiguration, replacing oldName: String? = nil, in json: String) throws -> String {
        var root = try JSONValue(parsing: Data(json.utf8)).object ?? [:]
        var servers = try ProjectMCP.servers(json)
        if server.name != oldName, servers[server.name] != nil { throw AgentError.launchFailed("A server named \(server.name) already exists.") }
        if let oldName { servers.removeValue(forKey: oldName) }
        servers[server.name] = server.configuration
        root["mcpServers"] = .object(servers)
        return try encode(root)
    }
    public static func enabled(_ enabled: Bool, name: String, in json: String) throws -> String {
        guard var config = try ProjectMCP.servers(json)[name]?.object else { throw AgentError.launchFailed("This server was removed.") }
        config["disabled"] = enabled ? nil : .bool(true)
        return try save(MCPServerConfiguration(name: name, configuration: .object(config)), replacing: name, in: json)
    }
    public static func remove(_ name: String, from json: String) throws -> String {
        var root = try JSONValue(parsing: Data(json.utf8)).object ?? [:]
        var servers = try ProjectMCP.servers(json); servers.removeValue(forKey: name)
        root["mcpServers"] = .object(servers)
        return try encode(root)
    }
    private static func encode(_ root: [String: JSONValue]) throws -> String {
        let bytes = try JSONValue.object(root).serialized()
        let pretty = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: bytes), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let text = String(decoding: pretty, as: UTF8.self)
        _ = try ProjectMCP.servers(text)
        return text
    }
}
