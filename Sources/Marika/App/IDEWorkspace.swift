import AppKit
import MarikaCore
import Observation

struct IDEResult: Identifiable {
    var id = UUID()
    var title: String
    var detail: String = ""
    var path: String?
    var line = 1
    var column = 1
    var edit: JSONValue?
    var sourceID: UUID?
    var sourceRevision: Int?
}

@MainActor @Observable final class IDEWorkspace {
    let editor: CodeWorkspace
    var context: ToolContext
    var preferences: IDEPreferences
    var panel = "Problems"
    var showsPanel = false
    var diagnostics: [String: [JSONValue]] = [:]
    var results: [IDEResult] = []
    var message = ""
    var status = "Ready"
    var pendingEdits: [(CodeDocument, String, String)] = []
    var testFramework = "Go"
    var tests: [ProjectTest] = []
    var testStatuses: [String: String] = [:]
    var testOutput = ""
    var testRunning = false
    var coverage: [String: [Int: Bool]] = [:]
    var debug = DebuggerSession()
    var breakpoints: [String: Set<Int>] = [:]
    var renameText = ""
    var debugProgram = ""
    var watchExpression = ""
    @ObservationIgnored private var services: [String: LanguageService] = [:]
    @ObservationIgnored private var starting: [String: Task<LanguageService, Error>] = [:]
    @ObservationIgnored private var listeners: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var testTask: Task<Void, Never>?
    @ObservationIgnored var inlineEdit: (service: LanguageService, apply: @MainActor (JSONValue) async throws -> Bool)?

    init(editor: CodeWorkspace, context: ToolContext, preferences: IDEPreferences) {
        self.editor = editor; self.context = context; self.preferences = preferences
        if FileManager.default.fileExists(atPath: context.root.appendingPathComponent("Package.swift").path) { testFramework = "Swift" }
        else if FileManager.default.fileExists(atPath: context.root.appendingPathComponent("pyproject.toml").path) { testFramework = "Python" }
    }
    var problemCount: Int { diagnostics.values.reduce(0) { $0 + $1.count } }
    func service(for document: CodeDocument) async throws -> LanguageService {
        let ext = URL(fileURLWithPath: document.path).pathExtension.lowercased()
        guard let integration = preferences.resolvedExtensions.first(where: { $0.enabled && $0.languages.contains(ext) }) else {
            throw AgentError.launchFailed("No language server configured for .\(ext). Add one in Project Settings → Editor extensions.")
        }
        if let service = services[integration.id] { return service }
        if let task = starting[integration.id] { return try await task.value }
        let task = Task { [self] in
            let (executable, args) = try context.invocation(integration.command, arguments: integration.arguments)
            let service = LanguageService(executable: executable, arguments: args, root: context.root, environment: context.environment,
                                          options: integration.initializationOptions ?? .null, remoteRoot: context.runtime?.directory)
            listeners[integration.id] = Task { [weak self] in
                for await event in service.events {
                    guard let self else { return }
                    if event["method"]?.string == "textDocument/publishDiagnostics", let uri = event["params"]?["uri"]?.string,
                       let path = await service.localPath(uri) {
                        diagnostics[path] = event["params"]?["diagnostics"]?.array ?? []
                    }
                    if event["method"]?.string == "workspace/applyEdit", let edit = event["params"]?["edit"] {
                        do {
                            if let inlineEdit, inlineEdit.service === service {
                                let applied = try await inlineEdit.apply(edit)
                                await service.respond(event, appliedEdit: applied)
                                continue
                            }
                            try await prepare(edit, service: service)
                        } catch { message = error.localizedDescription }
                    }
                    if event["method"]?.string == "marika/disconnected" {
                        services[integration.id] = nil; status = "Disconnected"
                    }
                    if event["id"] != nil { await service.respond(event) }
                }
            }
            do { try await service.start() }
            catch { await service.close(); listeners[integration.id]?.cancel(); throw error }
            services[integration.id] = service; status = integration.name
            return service
        }
        starting[integration.id] = task
        defer { starting[integration.id] = nil }
        return try await task.value
    }
    func synchronize(_ document: CodeDocument) async {
        guard document.isEditable else { return }
        do { let service = try await service(for: document); try await service.synchronize(path: document.path, text: document.text) }
        catch { status = error.localizedDescription }
    }
    func perform(_ action: String) {
        guard let document = editor.selectedDocument, document.isEditable else { return }
        showsPanel = true; panel = "Code"; message = ""; results = []
        Task { await perform(action, in: document) }
    }
    private func perform(_ action: String, in document: CodeDocument) async {
        do {
            let server = try await service(for: document)
            try await server.synchronize(path: document.path, text: document.text)
            let position = SourcePosition(line: document.line - 1, character: document.column - 1)
            let revision = document.revision
            let response: JSONValue
            switch action {
            case "Unfold": document.foldedRanges = []; return
            case "Fold":
                try await fold(document, server: server, position: position); return
            case "Format": try await format(document); message = "Formatted. Save the file to write these edits."; return
            case "Rename":
                guard !renameText.isEmpty else { message = "Enter the new symbol name."; return }
                response = try await server.request("textDocument/rename", path: document.path, position: position, extra: ["newName": .string(renameText)])
                guard document.revision == revision else { throw AgentError.launchFailed("The source changed. Request the refactoring again.") }
                try await prepare(response, service: server); return
            case "Refactor", "Organize imports":
                let offset = try SourcePosition.offset(position.json, in: document.text)
                let end = SourcePosition.at(offset: offset + document.selectionLength, in: document.text)
                let range: JSONValue = ["start": position.json, "end": end.json]
                let kinds: JSONValue = action == "Organize imports" ? ["source.organizeImports"] : ["quickfix", "refactor"]
                let context: JSONValue = ["diagnostics": .array(diagnostics[document.path] ?? []), "only": kinds]
                let extra: [String: JSONValue] = ["range": range, "context": context]
                response = try await server.request("textDocument/codeAction", path: document.path, position: position, extra: extra)
                results = (response.array ?? []).map { IDEResult(title: $0["title"]?.string ?? "Code action", edit: $0, sourceID: document.id, sourceRevision: revision) }; return
            case "Completions":
                response = try await server.request("textDocument/completion", path: document.path, position: position)
                results = (response.array ?? response["items"]?.array ?? []).prefix(100).map { item in
                    var copy = item
                    if item["textEdit"] == nil, var fields = item.object {
                        fields["textEdit"] = ["range": ["start": position.json, "end": position.json], "newText": item["insertText"] ?? item["label"] ?? ""]
                        copy = .object(fields)
                    }
                    return IDEResult(title: item["label"]?.string ?? "Completion", detail: item["detail"]?.string ?? "", path: document.path, edit: copy, sourceID: document.id, sourceRevision: revision)
                }; return
            case "Hover", "Signature":
                response = try await server.request(action == "Hover" ? "textDocument/hover" : "textDocument/signatureHelp", path: document.path, position: position)
                message = information(from: response)
                return
            case "Symbols": response = try await server.request("textDocument/documentSymbol", path: document.path, position: position)
            default:
                response = try await server.request(action == "References" ? "textDocument/references" : "textDocument/definition", path: document.path, position: position, extra: ["context": ["includeDeclaration": true]])
            }
            let items: [JSONValue] = response.array ?? (response.isNull ? [] : [response])
            for item in items { await appendLocation(item, document: document, server: server) }
            if results.isEmpty { message = "No results at this position." }
        } catch { message = error.localizedDescription }
    }

    private func fold(_ document: CodeDocument, server: LanguageService, position: SourcePosition) async throws {
        let uri = await server.uri(document.path)
        let value = try await server.request("textDocument/foldingRange", params: ["textDocument": ["uri": .string(uri)]])
        var best: (start: Int, end: Int)?
        for item in value.array ?? [] {
            guard let start = item["startLine"]?.int, let end = item["endLine"]?.int,
                  start <= position.line, end >= position.line, end > start else { continue }
            if best == nil || end - start < best!.end - best!.start { best = (start, end) }
        }
        guard let best,
              let lower = try? SourcePosition.offset(SourcePosition(line: best.start + 1, character: 0).json, in: document.text),
              let upper = try? SourcePosition.offset(SourcePosition(line: best.end, character: 0).json, in: document.text) else {
            message = "No foldable block at the cursor."; return
        }
        document.foldedRanges.append(NSRange(location: lower, length: upper - lower))
    }

    private func information(from response: JSONValue) -> String {
        if let text = response["contents"]?.string { return text }
        if let text = response["contents"]?["value"]?.string { return text }
        if let items = response["contents"]?.array {
            return items.map { $0.string ?? $0["value"]?.string ?? "" }.joined(separator: "\n")
        }
        if let signatures = response["signatures"]?.array {
            return signatures.map { $0["label"]?.string ?? "" }.joined(separator: "\n")
        }
        return "No information at this position."
    }

    private func appendLocation(_ value: JSONValue, document: CodeDocument, server: LanguageService) async {
        let uri = value["uri"]?.string ?? value["targetUri"]?.string ?? value["location"]?["uri"]?.string
        let path: String?
        if let uri { path = await server.localPath(uri) } else { path = document.path }
        let range = value["selectionRange"] ?? value["targetSelectionRange"] ?? value["range"] ?? value["location"]?["range"]
        let line = (range?["start"]?["line"]?.int ?? 0) + 1
        let column = (range?["start"]?["character"]?.int ?? 0) + 1
        results.append(IDEResult(title: value["name"]?.string ?? path ?? "Location", detail: path ?? "", path: path, line: line, column: column))
        for child in value["children"]?.array ?? [] { await appendLocation(child, document: document, server: server) }
    }
    func select(_ result: IDEResult) {
        Task {
            do {
                if var edit = result.edit, let document = editor.selectedDocument {
                    if let sourceID = result.sourceID, sourceID != document.id || result.sourceRevision != document.revision {
                        throw AgentError.launchFailed("The source changed. Request a fresh code action.")
                    }
                    let server = try await service(for: document)
                    let capabilities = await server.capabilities
                    if let reason = edit["disabled"]?["reason"]?.string { throw AgentError.protocolError(reason) }
                    if edit["edit"] == nil, edit["command"] == nil, edit["textEdit"] == nil,
                       capabilities["codeActionProvider"]?["resolveProvider"]?.bool == true {
                        edit = try await server.request("codeAction/resolve", params: edit)
                        guard result.sourceRevision == document.revision else { throw AgentError.protocolError("The source changed. Request the action again.") }
                    }
                    if let value = edit["edit"] { try await prepare(value, service: server) }
                    else if let textEdit = edit["textEdit"], let path = result.path {
                        let uri = await server.uri(path)
                        try await prepare(["changes": .object([uri: .array([textEdit] + (edit["additionalTextEdits"]?.array ?? []))])], service: server)
                    } else if let command = edit["command"] {
                        let value = command.string == nil ? command : edit
                        _ = try await server.request("workspace/executeCommand", params: ["command": value["command"] ?? command, "arguments": value["arguments"] ?? []])
                    }
                } else if let path = result.path {
                    await editor.open(path); editor.reveal(line: result.line, column: result.column)
                }
            } catch { message = error.localizedDescription }
        }
    }
    func format(_ document: CodeDocument) async throws {
        let text = document.text, server = try await service(for: document)
        try await server.synchronize(path: document.path, text: text)
        let uri = await server.uri(document.path)
        let settings = EditorSettings.shared.style
        let result = try await server.request("textDocument/formatting", params: ["textDocument": ["uri": .string(uri)], "options": ["tabSize": .int(Int64(settings.tabWidth)), "insertSpaces": .bool(!settings.usesTabs)]])
        guard document.text == text else { throw AgentError.launchFailed("The file changed while formatting. Try again.") }
        document.text = try SourcePosition.applying(result.array ?? [], to: text)
    }
    func prepare(_ value: JSONValue, service: LanguageService) async throws {
        var changes = value["changes"]?.object ?? [:]
        for change in value["documentChanges"]?.array ?? [] {
            guard let uri = change["textDocument"]?["uri"]?.string, let edits = change["edits"] else {
                throw AgentError.launchFailed("This refactoring includes file operations. Review it with the agent instead.")
            }
            changes[uri] = edits
        }
        var pending: [(CodeDocument, String, String)] = []
        for (uri, edits) in changes {
            guard let path = await service.localPath(uri) else { throw ProjectFileError.outsideProject }
            await editor.open(path, focus: false)
            guard let document = editor.documents.first(where: { $0.path == path }), document.isEditable else { throw ProjectFileError.notText }
            pending.append((document, document.text, try SourcePosition.applying(edits.array ?? [], to: document.text)))
        }
        pendingEdits = pending; message = pending.isEmpty ? "No edits returned." : "Review \(pending.count) changed files before applying."; showsPanel = true; panel = "Code"
    }
    func applyEdits() {
        guard pendingEdits.allSatisfy({ $0.0.text == $0.1 }) else { message = "Files changed since this preview. Request the refactoring again."; pendingEdits = []; return }
        for (document, _, text) in pendingEdits { document.text = text }
        pendingEdits = []; message = "Applied to editor drafts. Save to write the changes."
    }
    func insertSnippet(_ text: String) {
        guard let document = editor.selectedDocument,
              let offset = try? SourcePosition.offset(SourcePosition(line: document.line - 1, character: document.column - 1).json, in: document.text) else { return }
        document.text = (document.text as NSString).replacingCharacters(in: NSRange(location: offset, length: 0), with: text)
        editor.focusEditor()
    }
    func discoverTests() {
        guard !testRunning else { return }
        testRunning = true; showsPanel = true; panel = "Tests"
        testTask = Task {
            defer { testRunning = false }
            do { tests = try await ProjectTests.discover(context: context, framework: testFramework); testOutput = "Discovered \(tests.count) tests." }
            catch { testOutput = error.localizedDescription }
        }
    }
    func runTest(_ test: ProjectTest? = nil) {
        guard !testRunning else { return }
        testRunning = true; testOutput = "Running…"; showsPanel = true; panel = "Tests"
        testTask = Task {
            defer { testRunning = false }
            do {
                let result = try await ProjectTests.run(context: context, framework: testFramework, test: test)
                testStatuses.merge(result.statuses) { _, new in new }; testOutput = result.output; coverage = result.coverage
            } catch { testOutput = error.localizedDescription }
        }
    }
    func cancelTests() { testTask?.cancel() }
    func launchDebugger() {
        Task {
            do {
                showsPanel = true; panel = "Debug"
                let goProject = FileManager.default.fileExists(atPath: context.root.appendingPathComponent("go.mod").path)
                if context.runtime == nil, preferences.debug.adapter == "dlv" || (goProject && preferences.debug.adapter == "lldb-dap") {
                    let (executable, _) = try context.invocation("dlv")
                    await debug.start(executable: executable, arguments: [], root: context.root, environment: context.environment,
                        configuration: ["request": "launch", "mode": "debug", "program": .string(debugProgram.isEmpty ? context.root.path : debugProgram), "cwd": .string(context.root.path), "stopOnEntry": false],
                        breakpoints: breakpoints.mapValues { $0.sorted() }, go: true)
                } else {
                    let config = preferences.debug
                    let (executable, args) = try context.invocation(config.adapter, arguments: config.arguments)
                    await debug.start(executable: executable, arguments: args, root: context.root, environment: context.environment,
                        configuration: config.launch, breakpoints: breakpoints.mapValues { $0.sorted() }, sourceRoot: context.runtime?.directory)
                }
            } catch { message = error.localizedDescription; panel = "Code" }
        }
    }
    func shutdown() async {
        testTask?.cancel()
        for task in starting.values { task.cancel() }
        for listener in listeners.values { listener.cancel() }
        for service in services.values { await service.close() }
        services.removeAll(); starting.removeAll(); listeners.removeAll()
        await debug.stop()
    }
    func configure(_ preferences: IDEPreferences) {
        self.preferences = preferences
        let old = services
        services.removeAll(); diagnostics.removeAll()
        for task in starting.values { task.cancel() }
        starting.removeAll()
        for listener in listeners.values { listener.cancel() }
        listeners.removeAll()
        Task { for server in old.values { await server.close() } }
    }
}
