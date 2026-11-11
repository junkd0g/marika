import Foundation

public struct DeliverableSlide: Codable, Hashable, Sendable {
    public var title: String
    public var bullets: [String]
    public var notes: String?
}
public struct DeliverableSheet: Codable, Hashable, Sendable {
    public var name: String
    public var columns: [String]
    public var rows: [[String]]
}
public struct Deliverable: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case report, spreadsheet, presentation }
    public var kind: Kind
    public var title: String
    public var body: String?
    public var slides: [DeliverableSlide]?
    public var sheets: [DeliverableSheet]?
    public var sources: [ResearchSource]?
    public init(kind: Kind, title: String, body: String? = nil, slides: [DeliverableSlide]? = nil, sheets: [DeliverableSheet]? = nil, sources: [ResearchSource]? = nil) {
        self.kind = kind; self.title = title; self.body = body; self.slides = slides; self.sheets = sheets; self.sources = sources
    }
    public static func parse(_ json: String) throws -> Self {
        guard json.utf8.count <= 1_000_000 else { throw AgentError.launchFailed("Keep deliverables under 1 MB.") }
        let value = try JSONDecoder().decode(Self.self, from: Data(json.utf8)); try value.validate(); return value
    }
    public func validate() throws {
        guard textByteCount <= 1_000_000 else { throw AgentError.launchFailed("Keep deliverable text under 1 MB.") }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 180 else { throw AgentError.launchFailed("Give the deliverable a title under 180 characters.") }
        if let sources, !sources.isEmpty { try ResearchReport(answer: title, sources: sources, findings: []).validate() }
        switch kind {
        case .report:
            guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.utf8.count <= 150_000 else { throw AgentError.launchFailed("Reports need Markdown under 150 KB.") }; break
        case .presentation:
            guard let slides, !slides.isEmpty, slides.count <= 60,
                  slides.allSatisfy({ !$0.title.isEmpty && $0.title.count <= 200 && $0.bullets.count <= 12 && $0.bullets.allSatisfy { $0.count <= 700 } && ($0.notes?.count ?? 0) <= 5000 }) else {
                throw AgentError.launchFailed("Presentations need 1–60 slides with short titles and at most 12 concise bullets each.")
            }
        case .spreadsheet:
            guard let sheets, !sheets.isEmpty, sheets.count <= 12, Set(sheets.map { $0.name.lowercased() }).count == sheets.count,
                  sheets.allSatisfy({ sheet in
                    !sheet.name.isEmpty && sheet.name.count <= 31 && sheet.name.rangeOfCharacter(from: CharacterSet(charactersIn: "[]:*?/\\")) == nil &&
                    !sheet.columns.isEmpty && sheet.columns.count <= 50 && sheet.rows.count <= 1000 && sheet.columns.allSatisfy { $0.count <= 1000 } &&
                    sheet.rows.allSatisfy { $0.count == sheet.columns.count && $0.allSatisfy { $0.count <= 4000 } }
                  }) else { throw AgentError.launchFailed("Use 1–12 uniquely named sheets, up to 50 columns and 1,000 matching-width rows. Sheet names must be valid Excel names.") }
        }
    }

    // Keep accumulation explicit: nested reductions in one expression exceed the
    // type-checking budget of the Swift compiler shipped with Xcode 26.3.
    private var textByteCount: Int {
        var count = title.utf8.count + (body?.utf8.count ?? 0)
        for slide in slides ?? [] {
            count += slide.title.utf8.count
            count += slide.notes?.utf8.count ?? 0
            for bullet in slide.bullets { count += bullet.utf8.count }
        }
        for sheet in sheets ?? [] {
            count += sheet.name.utf8.count
            for column in sheet.columns { count += column.utf8.count }
            for row in sheet.rows {
                for cell in row { count += cell.utf8.count }
            }
        }
        for source in sources ?? [] {
            count += source.id.utf8.count
            count += source.title.utf8.count
            count += source.url.utf8.count
            count += source.excerpt.utf8.count
        }
        return count
    }

    public var markdown: String {
        var result = "# " + title + "\n\n"
        switch kind {
        case .report: result += body ?? ""
        case .presentation:
            for (index, slide) in (slides ?? []).enumerated() {
                result += "## \(index + 1). \(slide.title)\n\n" + slide.bullets.map { "- " + $0 }.joined(separator: "\n") + "\n\n"
                if let notes = slide.notes, !notes.isEmpty { result += "Notes: " + notes + "\n\n" }
            }
        case .spreadsheet:
            for sheet in sheets ?? [] {
                func row(_ cells: [String]) -> String { "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") + " |\n" }
                result += "## " + sheet.name + "\n\n" + row(sheet.columns) + row(sheet.columns.map { _ in "---" }) + sheet.rows.map(row).joined() + "\n"
            }
        }
        if let sources, !sources.isEmpty { result += "\n\n## Sources\n\n" + sources.map { "- [\($0.title)](\($0.url)) — \($0.excerpt)" }.joined(separator: "\n") }
        return result
    }
}
