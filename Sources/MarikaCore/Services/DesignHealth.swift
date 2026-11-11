import Foundation

public enum DesignFileHealth: Sendable, Equatable {
    case present, missing, outsideProject
    case unavailable(String)
}

public struct DesignHealthIssue: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case invalidLink, missingFile, outsideProject, missingEndpoint, missingSymbol, ambiguousSymbol, unverified, disconnected, brokenConnection }
    public let nodeID: UUID
    public let linkID: UUID?
    public let kind: Kind
    public let title: String
    public let detail: String
    public var id: String { nodeID.uuidString + ":" + (linkID?.uuidString ?? "") + ":" + kind.rawValue }
    public var needsRepair: Bool { ![.unverified, .disconnected].contains(kind) }
}

public enum DesignHealth {
    public static func file(_ path: String, root: URL) async -> DesignFileHealth {
        await Task.detached { () -> DesignFileHealth in
            let base = root.standardizedFileURL.resolvingSymlinksInPath()
            let file = base.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            guard !path.hasPrefix("/"), file.path.hasPrefix(base.path + "/") else { return .outsideProject }
            do {
                return try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true ? .present : .missing
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .missing }
            catch { return .unavailable(error.localizedDescription) }
        }.value
    }

    /// Read-only audit. A failed or unsupported language server is unverified, not a missing declaration.
    public static func scan(_ document: DesignDocument, endpointIDs: Set<String>,
                            file: @Sendable (String) async -> DesignFileHealth,
                            symbols: @Sendable (String) async -> Result<[SourceSymbol], SymbolLookupError>) async throws -> [DesignHealthIssue] {
        var issues: [DesignHealthIssue] = []
        var files: [String: DesignFileHealth] = [:]
        var declarations: [String: Result<[SourceSymbol], SymbolLookupError>] = [:]
        for node in document.nodes {
            for link in node.links ?? [] {
                try Task.checkCancellation()
                func issue(_ kind: DesignHealthIssue.Kind, _ title: String, _ detail: String) {
                    issues.append(DesignHealthIssue(nodeID: node.id, linkID: link.id, kind: kind, title: title, detail: detail))
                }
                guard link.isValid else { issue(.invalidLink, "Invalid link", link.target); continue }
                switch link.kind {
                case .documentation: break // Validate the URL without sending a network request.
                case .endpoint:
                    if !endpointIDs.contains(link.target) { issue(.missingEndpoint, "API endpoint not found", link.target) }
                case .file, .symbol:
                    if files[link.target] == nil { files[link.target] = await file(link.target) }
                    switch files[link.target]! {
                    case .missing: issue(.missingFile, "File not found", link.target); continue
                    case .outsideProject: issue(.outsideProject, "File is outside this project", link.target); continue
                    case .unavailable(let reason): issue(.unverified, "File could not be checked", link.target + "\n" + reason); continue
                    case .present: break
                    }
                    guard link.kind == .symbol else { continue }
                    if declarations[link.target] == nil { declarations[link.target] = await symbols(link.target) }
                    try Task.checkCancellation()
                    do {
                        _ = try SourceSymbols.resolve(link, in: declarations[link.target]!.get())
                    } catch let error as SymbolLookupError {
                        let kind: DesignHealthIssue.Kind
                        switch error {
                        case .missing: kind = .missingSymbol
                        case .ambiguous: kind = .ambiguousSymbol
                        case .unsupported, .unavailable, .changed: kind = .unverified
                        }
                        issue(kind, kind == .unverified ? "Symbol not verified" : kind == .ambiguousSymbol ? "Ambiguous symbol" : "Symbol not found",
                              link.target + "\n" + error.localizedDescription)
                    }
                }
            }
        }
        let all = Set(document.nodes.map(\.id)), visible = Set(document.nodes.filter { !$0.isHidden }.map(\.id))
        var connected = Set<UUID>()
        for edge in document.connections ?? [] {
            if !all.contains(edge.from) || !all.contains(edge.to) {
                issues.append(DesignHealthIssue(nodeID: all.contains(edge.from) ? edge.from : edge.to, linkID: edge.id,
                                               kind: .brokenConnection, title: "Connection has a missing endpoint", detail: edge.label))
            }
            if visible.contains(edge.from), visible.contains(edge.to), edge.from != edge.to { connected.formUnion([edge.from, edge.to]) }
        }
        let components = document.nodes.filter { !$0.isHidden && $0.component != nil }
        if components.count > 1 {
            for node in components where !connected.contains(node.id) {
                issues.append(DesignHealthIssue(nodeID: node.id, linkID: nil, kind: .disconnected, title: "Disconnected component",
                                               detail: "This component has no connection to another visible element. Leave it separate if that is intentional."))
            }
        }
        return issues
    }
}
