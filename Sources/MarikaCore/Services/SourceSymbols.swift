import Foundation

/// A declaration's identity is independent of its current line number.
public struct DesignSymbolIdentity: Codable, Hashable, Sendable {
    public var path: [String]
    public var kind: Int
    public var detail: String?
    public init(path: [String], kind: Int, detail: String? = nil) { self.path = path; self.kind = kind; self.detail = detail }
    public var name: String { path.joined(separator: ".") }
    public var isValid: Bool {
        !path.isEmpty && path.count <= 32 && path.allSatisfy { !$0.isEmpty && $0.count <= 500 }
            && (1...26).contains(kind) && (detail?.count ?? 0) <= 2_000
    }
}

public struct SourceSymbol: Hashable, Sendable, Identifiable {
    public let identity: DesignSymbolIdentity
    public let position: SourcePosition
    public let length: Int
    public var id: String { identity.name + ":\(identity.kind):\(position.line):\(position.character)" }
    public var name: String { identity.path.last ?? "" }
    public var subtitle: String { [identity.detail, "Line \(position.line + 1)"].compactMap { $0 }.joined(separator: " · ") }
}

public enum SymbolLookupError: Error, LocalizedError, Sendable, Equatable {
    case unsupported, unavailable(String), missing(String), ambiguous(String), changed
    public var errorDescription: String? {
        switch self {
        case .unsupported: "This language server does not provide document symbols. Configure a supported server in Project Settings → Editor."
        case .unavailable(let reason): "Symbol verification unavailable: " + reason
        case .missing(let name): "The declaration “\(name)” was not found. Choose its current symbol in Manage links."
        case .ambiguous(let name): "More than one declaration matches “\(name)”. Choose the exact symbol in Manage links."
        case .changed: "The source changed during symbol lookup. Check again."
        }
    }
}

public enum SourceSymbols {
    /// Accept both hierarchical DocumentSymbol and flat SymbolInformation responses.
    public static func parse(_ response: JSONValue, documentURI: String) -> [SourceSymbol] {
        var result: [SourceSymbol] = []
        func visit(_ values: [JSONValue], parents: [String], depth: Int) {
            guard depth < 32 else { return }
            for value in values where result.count < 10_000 {
                guard let name = value["name"]?.string, !name.isEmpty, name.count <= 500,
                      let kind = value["kind"]?.int, (1...26).contains(kind) else { continue }
                if let uri = value["location"]?["uri"]?.string, uri != documentURI { continue }
                let container = value["containerName"]?.string.flatMap { $0.isEmpty ? nil : $0 }
                let path = (parents.isEmpty ? container.map { [$0] } ?? [] : parents) + [name]
                let range = value["selectionRange"] ?? value["location"]?["range"] ?? value["range"]
                if let start = range?["start"], let line = start["line"]?.int, let column = start["character"]?.int,
                   let endLine = range?["end"]?["line"]?.int, let endColumn = range?["end"]?["character"]?.int,
                   (0...10_000_000).contains(line), (0...10_000_000).contains(column),
                   (line...10_000_000).contains(endLine), (0...10_000_000).contains(endColumn), endLine != line || endColumn >= column {
                    let identity = DesignSymbolIdentity(path: path, kind: kind, detail: value["detail"]?.string)
                    if identity.isValid {
                        result.append(SourceSymbol(identity: identity, position: SourcePosition(line: line, character: column),
                                                   length: endLine == line ? endColumn - column : 0))
                    }
                }
                visit(value["children"]?.array ?? [], parents: path, depth: depth + 1)
            }
        }
        visit(response.array ?? [], parents: [], depth: 0)
        var seen = Set<SourceSymbol>()
        return result.filter { seen.insert($0).inserted }
    }

    public static func resolve(_ link: DesignSourceLink, in symbols: [SourceSymbol]) throws -> SourceSymbol {
        let name = link.symbolIdentity?.name ?? link.symbol ?? ""
        guard !name.isEmpty else { throw SymbolLookupError.missing("Unspecified symbol") }
        let matches: [SourceSymbol]
        if let identity = link.symbolIdentity {
            matches = symbols.filter { $0.identity == identity }
        } else {
            matches = symbols.filter { $0.name == name || $0.identity.name == name }
        }
        guard !matches.isEmpty else { throw SymbolLookupError.missing(name) }
        guard matches.count == 1 else { throw SymbolLookupError.ambiguous(name) }
        return matches[0]
    }
}

extension LanguageService {
    public func symbols(path: String, text: String) async throws -> [SourceSymbol] {
        guard capabilities["documentSymbolProvider"] != nil, capabilities["documentSymbolProvider"]?.bool != false else {
            throw SymbolLookupError.unsupported
        }
        try Task.checkCancellation()
        try await synchronize(path: path, text: text)
        let documentURI = uri(path)
        let response = try await request("textDocument/documentSymbol", params: ["textDocument": ["uri": .string(documentURI)]])
        try Task.checkCancellation()
        return SourceSymbols.parse(response, documentURI: documentURI)
    }
}
