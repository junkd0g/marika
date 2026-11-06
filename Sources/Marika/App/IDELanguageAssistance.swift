import AppKit
import MarikaCore

struct EditorHover {
    var text: String
    var range: NSRange
}

struct EditorQuickFix: Identifiable {
    let id = UUID()
    var value: JSONValue
    var title: String { value["title"]?.string ?? "Quick fix" }
    var source: String
    var revision: Int
    var documentID: UUID
    var revisions: [String: Int]
}

extension IDEWorkspace {
    func supportsAssistance(for document: CodeDocument) -> Bool {
        let ext = URL(fileURLWithPath: document.path).pathExtension.lowercased()
        return document.isEditable && preferences.resolvedExtensions.contains { $0.enabled && $0.languages.contains(ext) }
    }

    func completions(in document: CodeDocument, text: String, offset: Int) async throws -> [LanguageCompletion] {
        let server = try await service(for: document)
        try Task.checkCancellation()
        guard document.text == text else { return [] }
        try await server.synchronize(path: document.path, text: text)
        let value = try await server.request("textDocument/completion", path: document.path,
            position: SourcePosition.at(offset: offset, in: text), extra: ["context": ["triggerKind": 1]])
        try Task.checkCancellation()
        guard document.text == text else { return [] }
        return LanguageAssistance.completions(value, text: text, offset: offset)
    }

    func resolve(_ completion: LanguageCompletion, in document: CodeDocument) async throws -> JSONValue {
        let server = try await service(for: document)
        let capabilities = await server.capabilities
        guard capabilities["completionProvider"]?["resolveProvider"]?.bool == true else { return completion.item }
        return try await server.request("completionItem/resolve", params: completion.item)
    }

    func hover(in document: CodeDocument, text: String, offset: Int) async throws -> EditorHover? {
        let server = try await service(for: document)
        try Task.checkCancellation()
        guard document.text == text else { return nil }
        let capabilities = await server.capabilities
        guard capabilities["hoverProvider"] != nil, capabilities["hoverProvider"]?.bool != false else { return nil }
        try await server.synchronize(path: document.path, text: text)
        let value = try await server.request("textDocument/hover", path: document.path, position: SourcePosition.at(offset: offset, in: text))
        try Task.checkCancellation()
        let content = LanguageAssistance.documentation(value["contents"])
        guard document.text == text, !content.isEmpty else { return nil }
        var range = LanguageAssistance.wordRange(in: text, at: offset)
        if let lower = value["range"]?["start"], let upper = value["range"]?["end"],
           let start = try? SourcePosition.offset(lower, in: text), let end = try? SourcePosition.offset(upper, in: text), end >= start {
            range = NSRange(location: start, length: end - start)
        }
        return EditorHover(text: content, range: range)
    }

    func signature(in document: CodeDocument, text: String, offset: Int) async throws -> LanguageSignature? {
        let server = try await service(for: document)
        try Task.checkCancellation()
        guard document.text == text else { return nil }
        let capabilities = await server.capabilities
        guard capabilities["signatureHelpProvider"] != nil else { return nil }
        try await server.synchronize(path: document.path, text: text)
        let value = try await server.request("textDocument/signatureHelp", path: document.path, position: SourcePosition.at(offset: offset, in: text))
        try Task.checkCancellation()
        guard document.text == text else { return nil }
        return LanguageAssistance.signature(value)
    }

    func quickFixes(in document: CodeDocument, text: String, range: NSRange) async throws -> [EditorQuickFix] {
        let revision = document.revision
        let revisions = Dictionary(uniqueKeysWithValues: editor.documents.map { ($0.path, $0.revision) })
        let server = try await service(for: document)
        try Task.checkCancellation()
        guard document.text == text else { return [] }
        try await server.synchronize(path: document.path, text: text)
        let relevant = (diagnostics[document.path] ?? []).filter { value in
            guard let a = value["range"]?["start"], let b = value["range"]?["end"],
                  let start = try? SourcePosition.offset(a, in: text), let end = try? SourcePosition.offset(b, in: text) else { return false }
            return start <= NSMaxRange(range) && end >= range.location
        }
        let value = try await server.request("textDocument/codeAction", path: document.path,
            position: SourcePosition.at(offset: range.location, in: text),
            extra: ["range": LanguageAssistance.jsonRange(range, in: text),
                    "context": ["diagnostics": .array(relevant), "only": ["quickfix"], "triggerKind": 1]])
        try Task.checkCancellation()
        guard document.text == text, document.revision == revision else { return [] }
        return (value.array ?? []).filter { $0["disabled"] == nil }.sorted {
            $0["isPreferred"]?.bool == true && $1["isPreferred"]?.bool != true
        }.prefix(30).map { EditorQuickFix(value: $0, source: text, revision: revision, documentID: document.id, revisions: revisions) }
    }

    /// Single-file fixes stay in the editor's undo stack. Project-wide fixes use the existing review.
    func apply(_ fix: EditorQuickFix, in document: CodeDocument, update: @escaping (String) -> Void) async throws {
        func validate() throws {
            try Task.checkCancellation()
            guard document.id == fix.documentID, document.revision == fix.revision, document.text == fix.source else {
                throw AgentError.protocolError("The code changed. Request the quick fix again.")
            }
            for doc in editor.documents where fix.revisions[doc.path] != nil {
                guard fix.revisions[doc.path] == doc.revision else { throw AgentError.protocolError("A project file changed. Request the quick fix again.") }
            }
        }
        try validate()
        let server = try await service(for: document)
        var action = fix.value
        let capabilities = await server.capabilities
        if action["edit"] == nil, action["command"] == nil, capabilities["codeActionProvider"]?["resolveProvider"]?.bool == true {
            action = try await server.request("codeAction/resolve", params: action)
        }
        try validate()
        guard action["edit"] != nil || action["command"] != nil else { throw AgentError.protocolError("This language server did not return an applicable quick fix.") }
        if let value = action["edit"] {
            let changes = try LanguageAssistance.textEdits(value)
            let uri = await server.uri(document.path)
            if changes.count == 1, let edits = changes[uri] {
                let updated = try SourcePosition.applying(edits, to: document.text)
                try validate()
                update(updated)
                try await server.synchronize(path: document.path, text: updated)
            } else {
                try await prepare(value, service: server)
                return
            }
        }
        if let command = action["command"] {
            guard inlineEdit == nil else { throw AgentError.protocolError("Wait for the current code action to finish.") }
            var expectedText = document.text
            inlineEdit = (server, { [weak self] value in
                guard let self else { return false }
                guard document.text == expectedText else { throw AgentError.protocolError("The code changed while the quick fix was running.") }
                let changes = try LanguageAssistance.textEdits(value)
                let uri = await server.uri(document.path)
                if changes.count == 1, let edits = changes[uri] {
                    let updated = try SourcePosition.applying(edits, to: expectedText)
                    update(updated); expectedText = updated
                    return true
                }
                try await prepare(value, service: server)
                return false
            })
            defer { inlineEdit = nil }
            let value = command.string == nil ? command : action
            let result = try await server.request("workspace/executeCommand", params: ["command": value["command"] ?? command, "arguments": value["arguments"] ?? []])
            if result["changes"] != nil || result["documentChanges"] != nil { _ = try await inlineEdit?.apply(result) }
        }
    }
}
