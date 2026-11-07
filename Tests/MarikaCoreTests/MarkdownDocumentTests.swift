import Foundation
import Testing
@testable import MarikaCore

struct MarkdownDocumentTests {
    @Test func richDocumentsRecognizeHeadingsTasksTablesAndImages() {
        let source = """
        # Project ###

        Overview
        ========

        - [x] Build it
        - [ ] Ship it

        | Name | Value |
        | --- | --- |
        | a\\|b | `x|y` |

        ![Architecture](<images/system diagram.png>)
        """
        let blocks = MarkdownParser.parse(source)
        #expect(blocks[0] == .heading(level: 1, text: "Project"))
        #expect(blocks[1] == .heading(level: 1, text: "Overview"))
        if case .list(let items) = blocks[2] {
            #expect(items.map(\.checked) == [true, false])
            #expect(items.map(\.text) == ["Build it", "Ship it"])
        } else { Issue.record("Expected a task list") }
        #expect(blocks[3] == .table(header: ["Name", "Value"], rows: [["a|b", "`x|y`"]]))
        #expect(blocks[4] == .image(alt: "Architecture", source: "images/system diagram.png"))
    }

    @Test func fencesKeepMarkdownSamplesAndIncompleteEditsIntact() {
        let source = "````markdown\n# Sample\n```swift\nlet x = 1\n```\n````\n\nDone"
        #expect(MarkdownParser.parse(source) == [.code(language: "markdown", text: "# Sample\n```swift\nlet x = 1\n```"), .paragraph("Done")])
        #expect(MarkdownParser.parse("```swift\nlet x = 1") == [.code(language: "swift", text: "let x = 1")])
        #expect(MarkdownParser.parse("# Title\r\n\r\nText") == [.heading(level: 1, text: "Title"), .paragraph("Text")])
    }

    @Test func headingAnchorsAreStableAndDisambiguateRepeatedSections() {
        let blocks = MarkdownParser.parse("# Hello, World!\n\n## Hello, World!\n\n## Café setup")
        #expect(MarkdownParser.headingAnchors(in: blocks) == [0: "hello-world", 1: "hello-world-1", 2: "café-setup"])
    }

    @Test func linksResolveFromTheDocumentAndCannotEscapeTheProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("external"), withDestinationURL: outside)
        let document = root.appendingPathComponent("docs/README.md")
        #expect(MarkdownResource.localURL("images/test%20image.png", document: document, root: root) == root.appendingPathComponent("docs/images/test image.png"))
        #expect(MarkdownResource.localURL("../README.md#section", document: document, root: root) == root.appendingPathComponent("README.md"))
        #expect(MarkdownResource.localURL("#section", document: document, root: root) == document)
        for reference in ["../../outside.txt", "../external/private.png", "//server/private.png", "file:///etc/passwd", "javascript:alert(1)", "https://example.com/image.png"] {
            #expect(MarkdownResource.localURL(reference, document: document, root: root) == nil)
        }
    }

    @Test @MainActor func markdownOpensInPreviewAndRestoresUnsavedSourceAndMode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("README.MD")
        try "# Saved".write(to: path, atomically: true, encoding: .utf8)
        let editor = CodeWorkspace(root: root)
        await editor.open("README.MD")
        let document = try #require(editor.selectedDocument)
        #expect(document.isEditable && document.isMarkdown)
        #expect(document.markdownPresentation == .preview)
        document.markdownPresentation = .split
        document.text = "# Unsaved\n\nA new paragraph."
        var layout = ProjectLayout()
        layout.files = editor.savedFiles; layout.selectedFile = document.path
        let restoredLayout = try JSONDecoder().decode(ProjectLayout.self, from: JSONEncoder().encode(layout))
        let restored = CodeWorkspace(root: root)
        await restored.restore(restoredLayout)
        let reopened = try #require(restored.selectedDocument)
        #expect(reopened.markdownPresentation == .split)
        #expect(reopened.text == document.text && reopened.isModified)
        #expect(try String(contentsOf: path, encoding: .utf8) == "# Saved")
        #expect(await restored.save(reopened))
        #expect(try String(contentsOf: path, encoding: .utf8) == document.text)
        reopened.markdownPresentation = .preview
        restored.reveal(line: 3)
        #expect(reopened.markdownPresentation == .source)
        reopened.markdownPresentation = .preview
        restored.findRequest += 1
        #expect(reopened.markdownPresentation == .source)
    }

    @Test func sourceHighlightingUsesMarkdownFormattingAndValidUnicodeOffsets() {
        let text = "# 🦊 Title\n\n**Bold** and `code` with [a link](README.md)\n\n```swift\nlet x = 1\n```"
        let tokens = CodeSyntax.tokens(in: text, path: "README.md")
        #expect(tokens.contains { $0.kind == .keyword && (text as NSString).substring(with: $0.range).hasPrefix("#") })
        #expect(tokens.contains { $0.kind == .function })
        #expect(tokens.contains { $0.kind == .string && (text as NSString).substring(with: $0.range) == "`code`" })
        for (index, token) in tokens.enumerated() {
            #expect(token.range.length > 0 && NSMaxRange(token.range) <= (text as NSString).length)
            if index > 0 { #expect(NSMaxRange(tokens[index - 1].range) <= token.range.location) }
        }
    }
}
