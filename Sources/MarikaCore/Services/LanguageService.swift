import Foundation

public struct SourcePosition: Codable, Hashable, Sendable {
    public var line: Int
    public var character: Int
    public init(line: Int, character: Int) { self.line = line; self.character = character }
    public var json: JSONValue { ["line": .int(Int64(line)), "character": .int(Int64(character))] }
    public static func at(offset: Int, in text: String) -> SourcePosition {
        let source = text as NSString, location = max(0, min(offset, source.length))
        var start = 0, line = 0
        while start < location {
            let end = NSMaxRange(source.lineRange(for: NSRange(location: start, length: 0)))
            if end > location { break }
            start = end; line += 1
        }
        return SourcePosition(line: line, character: location - start)
    }
    public static func offset(_ position: JSONValue, in text: String) throws -> Int {
        guard let line = position["line"]?.int, let column = position["character"]?.int, line >= 0, column >= 0 else {
            throw AgentError.protocolError("Invalid source position.")
        }
        let source = text as NSString
        var start = 0
        for _ in 0..<line {
            guard start < source.length else { throw AgentError.protocolError("Source position is past the document.") }
            start = NSMaxRange(source.lineRange(for: NSRange(location: start, length: 0)))
        }
        guard start + column <= source.length else { throw AgentError.protocolError("Source column is past the document.") }
        if start < source.length {
            let lineRange = source.lineRange(for: NSRange(location: start, length: 0))
            let content = source.substring(with: lineRange).trimmingCharacters(in: .newlines) as NSString
            guard column <= content.length else { throw AgentError.protocolError("Source column is past the line.") }
        }
        let offset = start + column
        guard Range(NSRange(location: offset, length: 0), in: text) != nil else { throw AgentError.protocolError("Source position splits a Unicode character.") }
        return offset
    }
    public static func applying(_ edits: [JSONValue], to text: String) throws -> String {
        let source = text as NSString
        let changes = try edits.map { edit -> (Int, Int, String) in
            guard let range = edit["range"], let start = range["start"], let end = range["end"], let replacement = edit["newText"]?.string else {
                throw AgentError.protocolError("Unsupported source edit.")
            }
            let lower = try offset(start, in: text), upper = try offset(end, in: text)
            guard upper >= lower else { throw AgentError.protocolError("Reversed source edit.") }
            return (lower, upper, replacement)
        }.sorted { $0.0 > $1.0 }
        var result = source as String, boundary = source.length + 1
        for (lower, upper, replacement) in changes {
            guard upper <= boundary else { throw AgentError.protocolError("Overlapping source edits.") }
            result = (result as NSString).replacingCharacters(in: NSRange(location: lower, length: upper - lower), with: replacement)
            boundary = lower
        }
        return result
    }
}

public actor LanguageService {
    public nonisolated let events: AsyncStream<JSONValue>
    private let rpc: FramedRPC
    private let root: URL
    private let remoteRoot: String?
    private var opened: [String: (Int, String)] = [:]
    private var task: Task<Void, Never>?
    private let options: JSONValue
    public private(set) var capabilities: JSONValue = [:]
    public init(executable: URL, arguments: [String], root: URL, environment: [String: String], options: JSONValue = .null, remoteRoot: String? = nil) {
        self.root = root; self.remoteRoot = remoteRoot; self.options = options
        rpc = FramedRPC(executable: executable, arguments: arguments, directory: root, environment: environment)
        events = rpc.events
    }
    public func start() async throws {
        try await rpc.start()
        let rootURI = URL(fileURLWithPath: remoteRoot ?? root.path).absoluteString
        let result = try await rpc.request("initialize", [
            "processId": .null, "clientInfo": ["name": "Marika", "version": "1"], "rootUri": .string(rootURI),
            "workspaceFolders": [["uri": .string(rootURI), "name": .string(root.lastPathComponent)]],
            "capabilities": ["general": ["positionEncodings": ["utf-16"]],
                "workspace": ["workspaceEdit": ["documentChanges": true], "configuration": true],
                "textDocument": ["completion": ["completionItem": ["snippetSupport": false, "insertReplaceSupport": true,
                    "documentationFormat": ["markdown", "plaintext"], "resolveSupport": ["properties": ["documentation", "detail", "additionalTextEdits"]]],
                    "completionList": ["itemDefaults": ["editRange", "insertTextFormat", "insertTextMode", "data"]]],
                    "hover": ["contentFormat": ["markdown", "plaintext"]],
                    "signatureHelp": ["signatureInformation": ["documentationFormat": ["markdown", "plaintext"], "parameterInformation": ["labelOffsetSupport": true], "activeParameterSupport": true]],
                    "codeAction": ["codeActionLiteralSupport": ["codeActionKind": ["valueSet": ["quickfix", "refactor", "source.organizeImports"]]],
                        "isPreferredSupport": true, "disabledSupport": true, "dataSupport": true, "resolveSupport": ["properties": ["edit"]]],
                    "publishDiagnostics": ["versionSupport": true]]],
            "initializationOptions": options], timeout: 30)
        capabilities = result["capabilities"] ?? [:]
        try await rpc.notify("initialized")
    }
    public func uri(_ path: String) -> String { URL(fileURLWithPath: remoteRoot ?? root.path).appendingPathComponent(path).absoluteString }
    public func localPath(_ uri: String) -> String? {
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        let prefix = (remoteRoot ?? root.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = "/" + prefix + "/"
        guard url.path.hasPrefix(base) else { return nil }
        return String(url.path.dropFirst(base.count))
    }
    public func synchronize(path: String, text: String) async throws {
        if let previous = opened[path] {
            guard previous.1 != text else { return }
            let version = previous.0 + 1
            try await rpc.notify("textDocument/didChange", ["textDocument": ["uri": .string(uri(path)), "version": .int(Int64(version))], "contentChanges": [["text": .string(text)]]])
            opened[path] = (version, text)
        } else {
            let ext = URL(fileURLWithPath: path).pathExtension
            let languages = ["ts": "typescript", "tsx": "typescriptreact", "js": "javascript", "jsx": "javascriptreact", "py": "python", "rs": "rust", "h": "c", "cpp": "cpp", "mod": "go.mod", "gql": "graphql", "graphqls": "graphql", "proto": "proto"]
            try await rpc.notify("textDocument/didOpen", ["textDocument": ["uri": .string(uri(path)), "languageId": .string(languages[ext] ?? ext), "version": 1, "text": .string(text)]])
            opened[path] = (1, text)
        }
    }
    public func request(_ method: String, path: String, position: SourcePosition, extra: [String: JSONValue] = [:]) async throws -> JSONValue {
        var params: [String: JSONValue] = ["textDocument": ["uri": .string(uri(path))], "position": position.json]
        params.merge(extra) { _, new in new }
        return try await rpc.request(method, .object(params), timeout: 30)
    }
    public func request(_ method: String, params: JSONValue) async throws -> JSONValue { try await rpc.request(method, params, timeout: 30) }
    public func respond(_ request: JSONValue, appliedEdit: Bool? = nil) async {
        guard let id = request["id"] else { return }
        let result: JSONValue
        switch request["method"]?.string {
        case "workspace/configuration": result = .array((request["params"]?["items"]?.array ?? []).map { _ in options })
        case "workspace/workspaceFolders": result = [["uri": .string(URL(fileURLWithPath: remoteRoot ?? root.path).absoluteString), "name": .string(root.lastPathComponent)]]
        case "workspace/applyEdit":
            result = appliedEdit == true ? ["applied": true] : ["applied": false, "failureReason": "Review the proposed edit in Marika before applying it."]
        default: result = .null
        }
        try? await rpc.respond(id: id, result: result)
    }
    public func close() async {
        task?.cancel()
        try? await rpc.notify("exit")
        await rpc.close()
    }
}
