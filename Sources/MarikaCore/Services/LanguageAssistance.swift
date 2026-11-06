import Foundation

public struct LanguageCompletion: Identifiable, Sendable {
    public let id: Int
    public let item: JSONValue
    public let label: String
    public let detail: String
    public let kind: Int
    public let source: String
    public let offset: Int

    public func applying(resolved: JSONValue? = nil, to text: String) throws -> (text: String, selection: NSRange) {
        guard text == source else { throw AgentError.protocolError("The code changed. Request a fresh completion.") }
        var fields = item.object ?? [:]
        if let resolved = resolved?.object { fields.merge(resolved) { _, new in new } }
        let value = JSONValue.object(fields)
        guard value["insertTextFormat"]?.int != 2 else { throw AgentError.protocolError("This completion requires snippet support.") }
        let fallback = LanguageAssistance.wordRange(in: text, at: offset)
        let replacement = value["textEdit"]?["newText"]?.string ?? value["textEditText"]?.string ?? value["insertText"]?.string ?? label
        let range = value["textEdit"]?["range"] ?? value["textEdit"]?["replace"] ?? value["textEdit"]?["insert"]
            ?? LanguageAssistance.jsonRange(fallback, in: text)
        guard let start = range["start"], let end = range["end"] else { throw AgentError.protocolError("Invalid completion range.") }
        let lower = try SourcePosition.offset(start, in: text), upper = try SourcePosition.offset(end, in: text)
        guard lower <= offset, upper >= offset else { throw AgentError.protocolError("Completion does not contain the cursor.") }
        let additional = value["additionalTextEdits"]?.array ?? []
        var displacement = 0
        for edit in additional {
            guard let start = edit["range"]?["start"], let end = edit["range"]?["end"], let newText = edit["newText"]?.string else {
                throw AgentError.protocolError("Invalid additional completion edit.")
            }
            let a = try SourcePosition.offset(start, in: text), b = try SourcePosition.offset(end, in: text)
            guard b <= lower || a >= upper, !(a == lower && b == lower) else { throw AgentError.protocolError("Overlapping completion edits.") }
            if b <= lower { displacement += (newText as NSString).length - (b - a) }
        }
        let edits: [JSONValue] = [["range": range, "newText": .string(replacement)]] + additional
        let result = try SourcePosition.applying(edits, to: text)
        return (result, NSRange(location: lower + displacement + (replacement as NSString).length, length: 0))
    }
}

public struct LanguageSignature: Sendable, Equatable {
    public var label: String
    public var documentation: String
    public var parameter: String?
}

public enum LanguageAssistance {
    public static func wordRange(in text: String, at offset: Int) -> NSRange {
        let source = text as NSString
        var lower = max(0, min(offset, source.length)), upper = lower
        func isWord(_ index: Int) -> Bool {
            guard index >= 0, index < source.length, let scalar = UnicodeScalar(source.character(at: index)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$"
        }
        while isWord(lower - 1) { lower -= 1 }
        while isWord(upper) { upper += 1 }
        return NSRange(location: lower, length: upper - lower)
    }

    public static func jsonRange(_ range: NSRange, in text: String) -> JSONValue {
        ["start": SourcePosition.at(offset: range.location, in: text).json,
         "end": SourcePosition.at(offset: NSMaxRange(range), in: text).json]
    }

    public static func completions(_ response: JSONValue, text: String, offset: Int) -> [LanguageCompletion] {
        guard offset >= 0, offset <= (text as NSString).length else { return [] }
        let defaults = response["itemDefaults"]
        let word = wordRange(in: text, at: offset)
        let prefix = (text as NSString).substring(with: NSRange(location: word.location, length: offset - word.location))
        return (response.array ?? response["items"]?.array ?? []).enumerated().compactMap { index, raw -> LanguageCompletion? in
            guard var item = raw.object, let label = raw["label"]?.string else { return nil }
            for key in ["insertTextFormat", "insertTextMode", "data", "commitCharacters"] where item[key] == nil { item[key] = defaults?[key] }
            guard item["insertTextFormat"]?.int != 2 else { return nil }
            if item["textEdit"] == nil, let range = defaults?["editRange"] {
                let newText = item["textEditText"] ?? item["insertText"] ?? .string(label)
                item["textEdit"] = range["start"] != nil
                    ? ["range": range, "newText": newText]
                    : ["insert": range["insert"] ?? .null, "replace": range["replace"] ?? .null, "newText": newText]
            }
            // Explicit edits may intentionally insert punctuation or a qualified expression.
            if item["textEdit"] == nil, !prefix.isEmpty,
               !(raw["filterText"]?.string ?? label).localizedCaseInsensitiveContains(prefix) { return nil }
            return LanguageCompletion(id: index, item: .object(item), label: label,
                detail: raw["labelDetails"]?["detail"]?.string ?? raw["detail"]?.string ?? "",
                kind: raw["kind"]?.int ?? 1, source: text, offset: offset)
        }.sorted {
            let a = $0.item["sortText"]?.string ?? $0.label, b = $1.item["sortText"]?.string ?? $1.label
            if a == b { return $0.id < $1.id }
            return a.localizedStandardCompare(b) == .orderedAscending
        }.prefix(100).map { $0 }
    }

    public static func documentation(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        if let text = value.string { return text }
        if let items = value.array { return items.map { documentation($0) }.filter { !$0.isEmpty }.joined(separator: "\n\n") }
        guard let text = value["value"]?.string else { return "" }
        if let language = value["language"]?.string { return "```\(language)\n\(text)\n```" }
        return text
    }

    public static func signature(_ value: JSONValue) -> LanguageSignature? {
        guard let signatures = value["signatures"]?.array, !signatures.isEmpty else { return nil }
        let index = value["activeSignature"]?.int ?? 0
        let signature = signatures[signatures.indices.contains(index) ? index : 0]
        guard let label = signature["label"]?.string else { return nil }
        let parameters = signature["parameters"]?.array ?? []
        let active = signature["activeParameter"]?.int ?? value["activeParameter"]?.int ?? 0
        var parameter: String?
        if parameters.indices.contains(active), let name = parameters[active]["label"] {
            parameter = name.string
            if let bounds = name.array, bounds.count == 2, let lower = bounds[0].int, let upper = bounds[1].int,
               lower >= 0, upper >= lower, upper <= (label as NSString).length {
                parameter = (label as NSString).substring(with: NSRange(location: lower, length: upper - lower))
            }
        }
        return LanguageSignature(label: label, documentation: documentation(signature["documentation"]), parameter: parameter)
    }

    public static func textEdits(_ workspaceEdit: JSONValue) throws -> [String: [JSONValue]] {
        var changes = (workspaceEdit["changes"]?.object ?? [:]).mapValues { $0.array ?? [] }
        for item in workspaceEdit["documentChanges"]?.array ?? [] {
            guard let uri = item["textDocument"]?["uri"]?.string, let edits = item["edits"]?.array else {
                throw AgentError.protocolError("This action includes file operations. Review it with the agent.")
            }
            changes[uri, default: []] += edits
        }
        return changes
    }
}
