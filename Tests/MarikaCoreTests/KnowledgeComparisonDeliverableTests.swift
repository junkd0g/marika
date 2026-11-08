import Foundation
import PDFKit
import Testing
@testable import MarikaCore

struct KnowledgeComparisonDeliverableTests {
    @Test func registeredOAuthRedirectsRemainRestrictedToTheLoopbackBoundary() async throws {
        for address in ["https://example.com/oauth/slack", "http://0.0.0.0:8765/oauth/slack", "http://127.0.0.1:80/oauth/slack", "http://127.0.0.1:8765/other", "http://127.0.0.1:8765/oauth/slack?redirect=outside"] {
            #expect(throws: AgentError.self) { try OAuthCallbackServer(state: "synthetic", redirect: URL(string: address)!) }
        }
        let callback = try OAuthCallbackServer(state: "synthetic", redirect: URL(string: "http://127.0.0.1:38765/oauth/slack")!)
        defer { callback.stop() }
        let redirect = try await callback.start()
        #expect(redirect.absoluteString == "http://127.0.0.1:38765/oauth/slack")
        var components = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "state", value: "synthetic"), URLQueryItem(name: "code", value: "synthetic-code")]
        let (_, response) = try await URLSession.shared.data(from: components.url!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await callback.code(timeout: 2) == "synthetic-code")
    }
    private func answer(_ conclusion: String) throws -> String {
        String(decoding: try JSONEncoder().encode(ComparisonAnswer(conclusion: conclusion, reasoning: "Inspected local evidence.", uncertainties: ["Run integration checks."], sources: [])), as: UTF8.self)
    }
    @Test func comparisonPublicationIsOwnedAndSynthesisNeedsBothIndependentAnswers() throws {
        var run = try ModelComparison(question: "Which cache should we use?")
        #expect(run.claudeID != run.codexID && run.analysisPrompt.contains(run.id.uuidString))
        #expect(throws: AgentError.self) { try run.publish(answer("Unrelated"), callerID: UUID()) }
        try run.publish(answer("Use a bounded cache"), callerID: run.claudeID)
        #expect(run.answers["codex"] == nil)
        #expect(throws: AgentError.self) { try run.synthesisPrompt() }
        try run.publish(answer("Measure before caching"), callerID: run.codexID)
        let prompt = try run.synthesisPrompt()
        #expect(prompt.contains("Use a bounded cache") && prompt.contains("Measure before caching"))
        run.synthesisID = UUID()
        let json = #"{"agreements":["Measure latency"],"disagreements":[{"topic":"Timing","claude":"Cache now","codex":"Measure first","resolution":"Benchmark before choosing"}],"recommendation":"Measure first","checks":["Load test"]}"#
        #expect(throws: AgentError.self) { try run.publish(json, callerID: run.claudeID) }
        try run.publish(json, callerID: run.synthesisID!)
        #expect(run.synthesis?.disagreements.count == 1)
        #expect(throws: AgentError.self) { try run.publish(answer("Revised"), callerID: run.codexID) }
    }
    @Test func comparisonPromptsBoundLargeResultsWithoutLeakingTheOtherAnswerIntoAnalysis() throws {
        var run = try ModelComparison(question: String(repeating: "q", count: 6000))
        let result = ComparisonAnswer(conclusion: "Specific conclusion", reasoning: String(repeating: "界", count: 24_000), uncertainties: [], sources: [])
        try result.validate()
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        try run.publish(json, callerID: run.claudeID); try run.publish(json, callerID: run.codexID)
        #expect(try run.synthesisPrompt().count < 32_000)
        #expect(!run.analysisPrompt.contains("Specific conclusion"))
    }
    @Test func approvedKnowledgeIsSearchableButProposalsCannotSilentlyChangeContext() throws {
        var library = ProjectKnowledge()
        let original = try KnowledgeEntry(title: "Cache decision", kind: .decision, content: "Use a bounded cache of 100 entries.")
        try library.save(original)
        let proposed = try KnowledgeEntry(title: original.title, kind: .decision, content: "Use a bounded cache of 500 entries.")
        let proposal = KnowledgeProposal(entry: proposed, replacesID: original.id, baseRevision: 1, reason: "Load test supports the larger bound.")
        try library.propose(proposal)
        #expect(library.search("cache").first?.excerpt.contains("100") == true)
        #expect(library.instructions.contains("untrusted reference data"))
        try library.approve(proposal.id)
        #expect(library.proposals.isEmpty && library.entries[0].revision == 2)
        #expect(library.history?.first == original)
        #expect(library.search("CACHE").first?.citation == "[K:\(original.id.uuidString):2:1]")
    }
    @Test func staleKnowledgeReplacementPreservesNewerContentAndThePendingProposal() throws {
        var library = ProjectKnowledge()
        let original = try KnowledgeEntry(title: "Deploy", kind: .decision, content: "Use the staging environment.")
        try library.save(original)
        let update = try KnowledgeEntry(title: "Deploy", kind: .decision, content: "Use the release environment.")
        let proposal = KnowledgeProposal(entry: update, replacesID: original.id, baseRevision: 1, reason: "Deployment decision")
        try library.propose(proposal)
        try library.save(try KnowledgeEntry(title: "Deploy", kind: .decision, content: "Wait for review."), replacing: original.id, revision: 1)
        #expect(throws: AgentError.self) { try library.approve(proposal.id) }
        #expect(library.entries[0].content == "Wait for review." && library.proposals.count == 1)
        #expect(throws: AgentError.self) { try KnowledgeEntry(title: "Link", kind: .link, content: "Snapshot", source: "https://secret:password@example.com") }
        #expect(throws: AgentError.self) { try KnowledgeEntry(title: "Link", kind: .link, content: "Snapshot", source: "file:///private/document") }
    }
    @Test func simpleAgentProposalGetsServerAssignedIdentityAndPersistsWithOldWorkspaceCompatibility() throws {
        let caller = UUID()
        let proposal = try KnowledgeProposal.parse(#"{"entry":{"title":"Compiler choice","kind":"decision","content":"Use Swift 6."},"reason":"Verified package manifest"}"#, sessionID: caller)
        #expect(proposal.entry.sessionID == caller && proposal.entry.revision == 1)
        var project = Project(path: "/tmp/synthetic-product")
        project.knowledge = ProjectKnowledge(); try project.knowledge?.propose(proposal)
        project.comparisons = [try ModelComparison(question: "Compare our options")]
        let data = try JSONEncoder().encode(project)
        #expect(try JSONDecoder().decode(Project.self, from: data) == project)
        let older = try JSONDecoder().decode(Project.self, from: Data(#"{"id":"6FE91BE5-2AFE-4B47-9A61-99DDFDC059A2","path":"/tmp/old","name":"Old"}"#.utf8))
        #expect(older.knowledge == nil && older.comparisons == nil)
    }
    @Test func knowledgePassagesAreBoundedAndPendingNewItemsAreExcluded() throws {
        var library = ProjectKnowledge()
        try library.save(KnowledgeEntry(title: "Release notes", kind: .document, content: String(repeating: "neutral ", count: 300) + "unique-token release"))
        try library.propose(KnowledgeProposal(entry: try KnowledgeEntry(title: "Secret draft", kind: .decision, content: "pending-only"), reason: "Needs review"))
        #expect(library.search("pending-only").isEmpty)
        #expect(library.search("unique-token", limit: 1).count == 1)
        #expect(library.search("release", limit: 1).allSatisfy { $0.excerpt.count <= 1200 })
        #expect(library.search(" ").isEmpty)
    }
    @Test func deliverablesRejectMalformedShapesAndKeepPreviewsInert() throws {
        let oversized = Deliverable(kind: .spreadsheet, title: "Oversized", sheets: [DeliverableSheet(name: "Data", columns: Array(repeating: "Column", count: 10), rows: Array(repeating: Array(repeating: String(repeating: "x", count: 200), count: 10), count: 1000))])
        #expect(throws: AgentError.self) { try DeliverableExport.data(oversized, format: .xlsx) }
        #expect(throws: AgentError.self) { try Deliverable.parse(#"{"kind":"spreadsheet","title":"Invalid","sheets":[{"name":"Table","columns":["A"],"rows":[["1","2"]]}]}"#) }
        let report = try Deliverable.parse(#"{"kind":"report","title":"Safe <report>","body":"<script>alert(1)</script><img src=https://example.com/tracker>"}"#)
        let html = DeliverableExport.html(report)
        #expect(!html.contains("<script>") && html.contains("&lt;script&gt;") && html.contains("default-src 'none'"))
        let pdf = try DeliverableExport.data(report, format: .pdf)
        #expect(PDFDocument(data: pdf)?.pageCount == 1)
        #expect(PDFDocument(data: pdf)?.string?.contains("Safe <report>") == true)
        #expect(throws: AgentError.self) { try DeliverableExport.data(report, format: .xlsx) }
    }
    @Test func reportPDFPaginatesWithoutDroppingTheEndOfTheDocument() throws {
        let report = Deliverable(kind: .report, title: "Long report", body: (0..<180).map { "Section \($0): This report preserves each line of its content when paginated." }.joined(separator: "\n\n") + "\nFINAL SENTINEL")
        let document = try #require(PDFDocument(data: DeliverableExport.data(report, format: .pdf)))
        #expect(document.pageCount > 1 && document.string?.contains("FINAL SENTINEL") == true)
    }
    @Test func officeExportsPreserveSourcesAlongsideTheAuthoredContent() async throws {
        let source = ResearchSource(id: "S1", title: "Synthetic source", url: "https://example.com/evidence", excerpt: "Synthetic evidence for export validation.")
        let table = Deliverable(kind: .spreadsheet, title: "Table", sheets: [DeliverableSheet(name: "Sources", columns: ["Value"], rows: [["Authored row"]])], sources: [source])
        let deck = Deliverable(kind: .presentation, title: "Deck", slides: [DeliverableSlide(title: "Decision", bullets: ["Authored slide"], notes: nil)], sources: [source])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("marika-source-exports-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (value, format, part) in [(table, DeliverableExport.Format.xlsx, "xl/worksheets/sheet2.xml"), (deck, .pptx, "ppt/slides/slide2.xml")] {
            let url = root.appendingPathComponent("export." + format.rawValue)
            try DeliverableExport.data(value, format: format).write(to: url)
            let result = try await Command.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", url.path, part], workingDirectory: root)
            #expect(result.status == 0 && result.output.contains(source.url) && result.output.contains(source.title))
        }
    }
    @Test func exportsPreserveUnicodeTextAndProtectSpreadsheetFormulas() async throws {
        let table = try Deliverable.parse(#"{"kind":"spreadsheet","title":"Release matrix","sheets":[{"name":"Options","columns":["Item","Value"],"rows":[["Café 東京","=HYPERLINK(\"https://example.com\")"],["Quoted, field","Line 1\nLine 2"]]},{"name":"Checks","columns":["Status"],"rows":[["Passed"]]}]}"#)
        let deck = try Deliverable.parse(#"{"kind":"presentation","title":"Release review","slides":[{"title":"Decision","bullets":["Café 東京","Evidence < assumptions"],"notes":"Verify rollout"},{"title":"Next","bullets":["Measure latency"]}]}"#)
        let csv = String(decoding: try DeliverableExport.data(table, format: .csv), as: UTF8.self)
        #expect(csv.contains("' =") == false && csv.contains("'=HYPERLINK") && csv.contains("\"Line 1\nLine 2\""))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("marika-exports-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (value, format) in [(table, DeliverableExport.Format.xlsx), (deck, .pptx)] {
            let url = root.appendingPathComponent("export." + format.rawValue)
            try DeliverableExport.data(value, format: format).write(to: url)
            let result = try await Command.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-t", url.path], workingDirectory: root)
            #expect(result.status == 0)
            let extracted = root.appendingPathComponent(format.rawValue)
            let unzip = try await Command.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-q", url.path, "-d", extracted.path], workingDirectory: root)
            #expect(unzip.status == 0)
            let files = FileManager.default.enumerator(at: extracted, includingPropertiesForKeys: nil)!.allObjects.compactMap { $0 as? URL }
            for file in files where ["xml", "rels"].contains(file.pathExtension) {
                let parser = XMLParser(data: try Data(contentsOf: file)); #expect(parser.parse(), "\(file.lastPathComponent): \(String(describing: parser.parserError))")
            }
            if format == .xlsx {
                let sheet = try String(contentsOf: extracted.appendingPathComponent("xl/worksheets/sheet1.xml"), encoding: .utf8)
                #expect(sheet.contains("Café 東京") && sheet.contains("=HYPERLINK") && !sheet.contains("<f>"))
            } else {
                let slide = try String(contentsOf: extracted.appendingPathComponent("ppt/slides/slide1.xml"), encoding: .utf8)
                #expect(slide.contains("Café 東京"))
                let notes = try String(contentsOf: extracted.appendingPathComponent("ppt/notesSlides/notesSlide1.xml"), encoding: .utf8)
                #expect(notes.contains("Verify rollout"))
                #expect(PDFDocument(data: try DeliverableExport.data(deck, format: .pdf))?.pageCount == 2)
            }
            if let destination = ProcessInfo.processInfo.environment["MARIKA_EXPORT_QA_DIR"] {
                try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: destination).appendingPathComponent(url.lastPathComponent))
            }
        }
    }
    @Test func expandedCatalogUsesDistinctGoogleRecipesAndKeepsTokensOutOfProjectJSON() async throws {
        #expect(ConnectionCatalogEntry.entries.count >= 9)
        let gmail = ConnectionCatalogEntry.entries.first { $0.id == "google-gmail" }!
        let calendar = ConnectionCatalogEntry.entries.first { $0.id == "google-calendar" }!
        #expect(gmail.configuredServer(in: [calendar.server]) == nil)
        #expect(gmail.configuredServer(in: [gmail.server]) != nil && gmail.setup?.contains("0.5.0") == true)
        let github = ConnectionCatalogEntry.entries.first { $0.id == "github" }!
        #expect(github.usesToken && github.server.configuration["headers"] == nil)
        let token = try MCPOAuthCredential.bearer("synthetic-test-token", resource: URL(string: github.endpoint)!)
        #expect(token.refreshToken == nil && token.expiresAt.timeIntervalSinceNow > 3600)
        #expect(throws: AgentError.self) { try MCPOAuthCredential.bearer("token\nheader", resource: URL(string: github.endpoint)!) }
        #expect(ConnectionCatalogEntry.entries.first { $0.id == "slack" }?.requiresClientID == true)
        for entry in ConnectionCatalogEntry.entries {
            let config = try MCPConfigurationEditor.save(entry.server, in: "{\"mcpServers\":{}}")
            #expect(try ProjectMCP.servers(config).count == 1)
        }
    }
}
