import Foundation

public struct ScanFile: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var lines: Int
    public var id: String { path }
}

public struct ScanMarker: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var line: Int
    public var text: String
    public var id: String { path + ":" + String(line) }
}

public struct ScanInventory: Codable, Hashable, Sendable {
    public var sourceLines: Int
    public var testLines: Int
    public var testFiles: Int
    public var generatedLines: Int
    public var generatedFiles: Int
    public var excludedFiles: Int
    public var modules: [String: Int]
    public var largestFiles: [ScanFile]
    public var markers: [ScanMarker]
}

public struct ScanFinding: Codable, Hashable, Sendable, Identifiable {
    public enum Severity: String, Codable, CaseIterable, Sendable {
        case high, medium, low
        public var rank: Int { switch self { case .high: 0; case .medium: 1; case .low: 2 } }
    }
    public enum Category: String, Codable, CaseIterable, Sendable {
        case correctness, security, reliability, performance, testing, maintainability
    }
    public var title: String
    public var severity: Severity
    public var category: Category
    public var path: String
    public var line: Int
    public var evidence: String
    public var impact: String
    public var action: String
    public var id: String { path + ":" + String(line) + ":" + title }
}

public struct ScanReview: Codable, Hashable, Sendable {
    public var summary: String
    public var inspectedFiles: [String]
    public var findings: [ScanFinding]

    public func validate(at root: URL) async throws {
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              summary.count <= 2400, inspectedFiles.count <= 100, findings.count <= 30 else {
            throw AgentError.launchFailed("Keep the review summary under 2,400 characters and include at most 30 findings and 100 inspected files.")
        }
        guard Set(findings.map(\.id)).count == findings.count else { throw AgentError.launchFailed("Remove duplicate findings.") }
        let reader = ProjectFiles(root: root)
        for path in Set(inspectedFiles + findings.map(\.path)) { _ = try await reader.read(path) }
        for finding in findings {
            let source = try await reader.read(finding.path)
            let lines = source.text.components(separatedBy: "\n")
            let evidence = finding.evidence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard finding.line > 0, finding.line <= lines.count,
                  !finding.title.isEmpty, finding.title.count <= 180,
                  !finding.impact.isEmpty, !finding.action.isEmpty, !evidence.isEmpty,
                  finding.impact.count <= 2000, finding.action.count <= 2000, evidence.count <= 1200,
                  source.text.contains(evidence),
                  lines[finding.line - 1].contains(evidence.components(separatedBy: "\n")[0]) else {
                throw AgentError.launchFailed("Each finding needs a valid source line, an exact code excerpt, impact and a specific next action: " + finding.title)
            }
        }
    }
}
