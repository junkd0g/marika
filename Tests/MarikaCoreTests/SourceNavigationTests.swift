import Foundation
import Testing
@testable import MarikaCore

struct SourceNavigationTests {
    @Test func locationAndLocationLinkResponsesAreNormalizedAndDeduplicated() throws {
        let range: JSONValue = ["start": ["line": 3, "character": 2], "end": ["line": 3, "character": 8]]
        let response: JSONValue = [["uri": "file:///project/a.go", "range": range], ["targetUri": "file:///project/a.go", "targetSelectionRange": range],
            ["targetUri": "file:///project/b.go", "targetSelectionRange": range], ["uri": "file:///project/invalid.go"]]
        let locations = SourceNavigation.locations(response)
        #expect(locations.count == 2)
        #expect(locations[0].line == 4 && locations[0].column == 3 && locations[0].length == 6)
        #expect(SourceNavigation.locations(.null).isEmpty)
    }

    @Test func terminalLocationsCoverCompilersPythonAndJavaScript() throws {
        for (text, path, line, column) in [
            ("main.go:12:9: undefined: value", "main.go", 12, 9),
            ("/tmp/project/src/main.swift:8:2: error: wrong type", "/tmp/project/src/main.swift", 8, 2),
            (#"  File "/tmp/my project/app.py", line 23, in main"#, "/tmp/my project/app.py", 23, 1),
            ("    at load (/tmp/project/app.ts:19:7)", "/tmp/project/app.ts", 19, 7),
            ("src/app.ts(14,2): error TS1005", "src/app.ts", 14, 2)
        ] {
            let match = try #require(TerminalFileLink.find(in: text).first)
            #expect(match.path == path && match.line == line && match.column == column)
            #expect((text as NSString).substring(with: match.range).contains(path))
        }
        #expect(TerminalFileLink.find(in: "https://example.test/app.js:12:3").isEmpty)
        #expect(TerminalFileLink.find(in: "plain text:123").isEmpty)
    }

    @MainActor @Test func navigationRemembersPositionsIncludingSameFileJumpsAndDrafts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.swift", "b.swift"] { try Data("one\ntwo\nthree\nfour\n".utf8).write(to: root.appendingPathComponent(name)) }
        let editor = CodeWorkspace(root: root)
        await editor.open("a.swift"); editor.reveal(line: 2, column: 2)
        editor.selectedDocument?.text += "// unsaved\n"
        await editor.navigate(to: "a.swift", line: 4)
        editor.goBack()
        #expect(editor.selectedDocument?.line == 2 && editor.selectedDocument?.column == 2)
        #expect(editor.selectedDocument?.isModified == true)
        editor.goForward(); #expect(editor.selectedDocument?.line == 4)
        await editor.navigate(to: "b.swift", line: 3)
        editor.goBack(); #expect(editor.selectedDocument?.path == "a.swift" && editor.selectedDocument?.line == 4)
        #expect(try await editor.previewText("a.swift").contains("unsaved"))
        let link = try #require(TerminalFileLink.find(in: "a.swift:2:2").first)
        #expect(link.resolved(relativeTo: root, allowedRoots: [root])?.path == "a.swift")
        #expect(link.resolved(relativeTo: root, allowedRoots: [root.appendingPathComponent("other")]) == nil)
    }
}
