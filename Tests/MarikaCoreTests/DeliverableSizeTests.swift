import Foundation
import Testing
@testable import MarikaCore

struct DeliverableSizeTests {
    private func atLimit() -> Deliverable {
        // Title, sheet name and column header contribute three bytes. The cell
        // text contributes 998001 + 1996 bytes, including multibyte characters.
        var rows = Array(repeating: [String(repeating: "€", count: 333)], count: 999)
        rows.append([String(repeating: "é", count: 998)])
        return Deliverable(kind: .spreadsheet, title: "T", sheets: [DeliverableSheet(name: "S", columns: ["C"], rows: rows)])
    }

    private func expectTextLimit(_ value: Deliverable) {
        do {
            try value.validate()
            Issue.record("Accepted more than one megabyte of deliverable text")
        } catch {
            #expect(error.localizedDescription == "Keep deliverable text under 1 MB.")
        }
    }

    @Test func aggregateLimitCountsUTF8BytesAndIncludesTheExactBoundary() throws {
        var value = atLimit()
        try value.validate()
        value.sheets?[0].rows[999][0] += "x"
        expectTextLimit(value)
    }

    @Test func aggregateLimitIncludesNestedContentEvenForOtherDeliverableKinds() {
        let text = String(repeating: "é", count: 100_001)
        let slide = DeliverableSlide(title: text, bullets: [text], notes: text)
        let sheet = DeliverableSheet(name: "S", columns: [text], rows: [[text]])
        let value = Deliverable(kind: .report, title: "Report", body: "Body", slides: [slide], sheets: [sheet])
        expectTextLimit(value)
    }

    @Test func sourceMetadataIsIncludedInTheAggregateLimit() throws {
        var value = atLimit()
        value.sources = [ResearchSource(id: "source", title: "Evidence", url: "https://example.com/evidence", excerpt: "Verified passage")]
        expectTextLimit(value)
    }
}
