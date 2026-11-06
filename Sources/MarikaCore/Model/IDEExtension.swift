import Foundation

/// Declarative, reviewable integrations. Executables remain separate tools; importing a
/// manifest never downloads or runs code.
public struct IDEExtension: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var languages: [String]
    public var command: String
    public var arguments: [String]
    public var enabled: Bool
    public var initializationOptions: JSONValue?
    public init(id: String, name: String, languages: [String], command: String, arguments: [String] = [], enabled: Bool = true) {
        self.id = id; self.name = name; self.languages = languages; self.command = command; self.arguments = arguments; self.enabled = enabled
    }
    public func validate() throws {
        guard !id.isEmpty, !name.isEmpty, !command.isEmpty, !command.contains("\0"), !languages.isEmpty,
              arguments.allSatisfy({ !$0.contains("\0") }), languages.count <= 50 else {
            throw AgentError.launchFailed("An editor extension needs an ID, name, language extensions, and executable command.")
        }
    }
    public static let builtins: [IDEExtension] = [
        .init(id: "go", name: "Go", languages: ["go", "mod"], command: "gopls"),
        .init(id: "swift", name: "Swift", languages: ["swift"], command: "sourcekit-lsp"),
        .init(id: "typescript", name: "TypeScript / JavaScript", languages: ["ts", "tsx", "js", "jsx", "mjs", "cjs"], command: "typescript-language-server", arguments: ["--stdio"]),
        .init(id: "python", name: "Python", languages: ["py"], command: "pyright-langserver", arguments: ["--stdio"]),
        .init(id: "rust", name: "Rust", languages: ["rs"], command: "rust-analyzer"),
        .init(id: "graphql", name: "GraphQL", languages: ["graphql", "gql", "graphqls"], command: "graphql-lsp", arguments: ["server", "-m", "stream"]),
        .init(id: "protobuf", name: "Protobuf / gRPC", languages: ["proto"], command: "buf", arguments: ["lsp", "serve"]),
        .init(id: "clang", name: "C / C++", languages: ["c", "cpp", "h", "hpp", "m", "mm"], command: "clangd"),
    ]
}

public struct DebugConfiguration: Codable, Hashable, Sendable {
    public var adapter: String
    public var arguments: [String]
    public var launch: JSONValue
    public init(adapter: String = "lldb-dap", arguments: [String] = [], launch: JSONValue = ["request": "launch", "program": "", "stopOnEntry": true]) {
        self.adapter = adapter; self.arguments = arguments; self.launch = launch
    }
}

public struct IDEPreferences: Codable, Hashable, Sendable {
    public var extensions: [IDEExtension] = []
    public var formatOnSave = false
    public var debug = DebugConfiguration()
    public init() {}
    public var resolvedExtensions: [IDEExtension] {
        extensions + IDEExtension.builtins.filter { builtin in !extensions.contains { $0.id == builtin.id } }
    }
}
