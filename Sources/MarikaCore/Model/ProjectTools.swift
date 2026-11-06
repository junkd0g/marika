import Foundation

public struct ProjectAction: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var command: String
    public init(name: String, command: String) { self.name = name; self.command = command }
}

public struct ProjectSkill: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var instructions: String
    public var enabled = true
    public init(name: String, instructions: String) { self.name = name; self.instructions = instructions }
}

public struct ProjectSchedule: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var prompt: String
    public var agent: AgentKind
    public var model: String?
    public var hours: Int
    public var enabled = true
    public var nextRun: Date
    public var runs: [UUID] = []
    public var lastError: String?
    public init(name: String, prompt: String, agent: AgentKind, model: String? = nil, hours: Int) {
        self.name = name; self.prompt = prompt; self.agent = agent; self.model = model
        self.hours = max(1, hours); nextRun = Date().addingTimeInterval(Double(max(1, hours)) * 3600)
    }
}

public struct ProjectTools: Codable, Hashable, Sendable {
    public var setupCommand = ""
    public var actions: [ProjectAction] = []
    public var skills: [ProjectSkill] = []
    public var mcpConfig = "{\"mcpServers\":{}}"
    public var schedules: [ProjectSchedule] = []
    public var memory: String?
    public var hooks: [ProjectHook]?
    public var remoteMachines: [RemoteMachine]?
    public var completionsEnabled: Bool?
    public var ide: IDEPreferences?
    public init() {}
    public var instructions: String {
        ([memory.map { "Project memory\n" + $0 }].compactMap { $0 } + skills.filter(\.enabled).map { "Project playbook — \($0.name)\n\($0.instructions)" }).joined(separator: "\n\n")
    }
}

public enum ProjectMCP {
    public static func servers(_ json: String) throws -> [String: JSONValue] {
        guard let servers = try JSONValue(parsing: Data(json.utf8))["mcpServers"]?.object else {
            throw AgentError.launchFailed("Provide JSON with an mcpServers object.")
        }
        for (name, config) in servers {
            guard name != "marika_browser", name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
                throw AgentError.launchFailed("Use letters, numbers, dashes or underscores for server names; marika_browser is reserved.")
            }
            guard config["command"]?.string != nil || config["url"]?.string != nil else {
                throw AgentError.launchFailed("Server \(name) needs a command or URL.")
            }
            guard config["command"] == nil || config["url"] == nil else { throw AgentError.launchFailed("Server \(name) needs either a local command or a remote URL, not both.") }
            if let command = config["command"]?.string, command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw AgentError.launchFailed("Server \(name) needs a command.") }
            if let url = config["url"]?.string {
                guard let address = URL(string: url), ["http", "https"].contains(address.scheme?.lowercased()),
                      address.host?.isEmpty == false else { throw AgentError.launchFailed("Server \(name) needs an HTTP or HTTPS URL.") }
            }
            if let type = config["type"], !["stdio", "http", "sse"].contains(type.string) {
                throw AgentError.launchFailed("Server \(name) has an unsupported transport.")
            }
            if let args = config["args"], args.array?.allSatisfy({ $0.string != nil }) != true {
                throw AgentError.launchFailed("Server arguments must be an array of strings.")
            }
            for key in ["env", "headers", "http_headers"] {
                if let fields = config[key], fields.object?.values.allSatisfy({ $0.string != nil }) != true { throw AgentError.launchFailed("Server \(name): \(key) must contain string values.") }
            }
        }
        return servers
    }

    public static func resolved(_ servers: [String: JSONValue], environment: [String: String]) throws -> [String: JSONValue] {
        func expand(_ value: String) throws -> String {
            let pattern = try NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"#)
            var output = value
            for match in pattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
                let name = (value as NSString).substring(with: match.range(at: 1))
                guard let replacement = environment[name], let range = Range(match.range, in: output) else {
                    throw AgentError.launchFailed("Missing environment variable " + name + " for MCP connection.")
                }
                output.replaceSubrange(range, with: replacement)
            }
            return output
        }
        var result: [String: JSONValue] = [:]
        for (name, original) in servers {
            if original["disabled"]?.bool == true { continue }
            guard var config = original.object else { continue }
            for key in ["url", "command"] {
                if let value = config[key]?.string { config[key] = .string(try expand(value)) }
            }
            if let args = config["args"]?.array {
                config["args"] = .array(try args.map { .string(try expand($0.string ?? "")) })
            }
            for key in ["env", "headers", "http_headers"] {
                if let fields = config[key]?.object {
                    var expanded: [String: JSONValue] = [:]
                    for (field, value) in fields {
                        guard let text = value.string else { throw AgentError.launchFailed("MCP environment and header values must be strings.") }
                        expanded[field] = .string(try expand(text))
                    }
                    config[key] = .object(expanded)
                }
            }
            if config["headers"] == nil, let fields = config["http_headers"] { config["headers"] = fields }
            result[name] = .object(config)
        }
        return result
    }

    public static func claudeServers(_ servers: [String: JSONValue], environment: [String: String], deferCredentials: Bool = false) throws -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for (name, value) in servers {
            guard let config = value.object else { continue }
            var accepted = config.filter { ["command", "args", "env", "url", "headers", "type"].contains($0.key) }
            if config["url"] != nil { accepted["type"] = config["type"] ?? "http" }
            var headers = accepted["headers"]?.object ?? [:]
            for (header, variable) in config["env_http_headers"]?.object ?? [:] {
                guard let key = variable.string, let text = environment[key] else { throw AgentError.launchFailed("Missing environment variable for " + header) }
                headers[header] = .string(deferCredentials ? "${\(key)}" : text)
            }
            if let variable = config["bearer_token_env_var"]?.string {
                guard let token = environment[variable] else { throw AgentError.launchFailed("Missing environment variable " + variable) }
                headers["Authorization"] = .string("Bearer " + (deferCredentials ? "${\(variable)}" : token))
            }
            if !headers.isEmpty { accepted["headers"] = .object(headers) }
            var env = accepted["env"]?.object ?? [:]
            for variable in config["env_vars"]?.array ?? [] {
                guard let key = variable.string, let text = environment[key] else { throw AgentError.launchFailed("Missing MCP environment variable") }
                env[key] = .string(text)
            }
            if !env.isEmpty { accepted["env"] = .object(env) }
            result[name] = .object(accepted)
        }
        return result
    }

    public static func codexArguments(_ servers: [String: JSONValue]) throws -> [String] {
        var arguments: [String] = []
        for name in servers.keys.sorted() {
            guard let config = servers[name]?.object else { continue }
            for key in ["command", "args", "url", "env", "env_vars", "http_headers", "env_http_headers", "bearer_token_env_var"] {
                guard let value = config[key] ?? (key == "http_headers" ? config["headers"] : nil) else { continue }
                arguments += ["-c", "mcp_servers.\(name).\(key)=" + (try toml(value))]
            }
        }
        return arguments
    }
    private static func toml(_ value: JSONValue) throws -> String {
        if let fields = value.object {
            return "{" + (try fields.keys.sorted().map { key in
                let quoted = String(decoding: try JSONValue.string(key).serialized(), as: UTF8.self)
                return quoted + "=" + (try toml(fields[key]!))
            }).joined(separator: ",") + "}"
        }
        if let array = value.array { return "[" + (try array.map(toml)).joined(separator: ",") + "]" }
        return String(decoding: try value.serialized(), as: UTF8.self)
    }
}
