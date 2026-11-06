import Foundation
import Testing
@testable import MarikaCore

@Suite struct LanguageAssistanceTests {
    @Test func completesTheExistingWordInsteadOfDuplicatingItsPrefix() throws {
        let source = "let value = pri"
        let response: JSONValue = [["label": "private", "sortText": "2"], ["label": "print", "sortText": "1"], ["label": "unrelated"]]
        let items = LanguageAssistance.completions(response, text: source, offset: (source as NSString).length)
        #expect(items.map(\.label) == ["print", "private"])
        let result = try #require(items.first).applying(to: source)
        #expect(result.text == "let value = print")
        #expect(result.selection == NSRange(location: result.text.utf16.count, length: 0))
    }

    @Test func completionDefaultsReplaceSuffixAndPreserveResolveData() throws {
        let source = "fmt.Printx"
        let range: JSONValue = ["start": ["line": 0, "character": 4], "end": ["line": 0, "character": 10]]
        let response: JSONValue = ["itemDefaults": ["editRange": ["insert": ["start": ["line": 0, "character": 4], "end": ["line": 0, "character": 6]], "replace": range], "data": ["id": 42]], "items": [["label": "Printf", "textEditText": "Printf"]]]
        let item = try #require(LanguageAssistance.completions(response, text: source, offset: 6).first)
        #expect(item.item["data"]?["id"]?.int == 42)
        #expect(try item.applying(to: source).text == "fmt.Printf")
    }

    @Test func completionAppliesImportsAndKeepsTheCaretAtTheInsertion() throws {
        let source = "// 🦊\npackage main\nfunc main() { Pr }\n"
        let prefix = (source as NSString).range(of: "Pr")
        let response: JSONValue = [["label": "Println", "textEdit": ["range": LanguageAssistance.jsonRange(prefix, in: source), "newText": "fmt.Println"],
            "additionalTextEdits": [["range": ["start": ["line": 2, "character": 0], "end": ["line": 2, "character": 0]], "newText": "import \"fmt\"\n"]]]]
        let item = try #require(LanguageAssistance.completions(response, text: source, offset: NSMaxRange(prefix)).first)
        let result = try item.applying(to: source)
        #expect(result.text == "// 🦊\npackage main\nimport \"fmt\"\nfunc main() { fmt.Println }\n")
        #expect(result.selection.location == NSMaxRange((result.text as NSString).range(of: "fmt.Println")))
    }

    @Test func rejectsStaleAndOverlappingCompletions() throws {
        let source = "pri"
        let range = LanguageAssistance.jsonRange(NSRange(location: 0, length: 3), in: source)
        let item = try #require(LanguageAssistance.completions([["label": "print"]], text: source, offset: 3).first)
        #expect(throws: AgentError.self) { try item.applying(to: "private") }
        let bad: JSONValue = ["textEdit": ["range": range, "newText": "print"], "additionalTextEdits": [["range": range, "newText": "oops"]]]
        #expect(throws: AgentError.self) { try item.applying(resolved: bad, to: source) }
    }

    @Test func doesNotInsertUnadvertisedSnippetPlaceholders() {
        let response: JSONValue = [["label": "print", "insertText": "print(${1:value})", "insertTextFormat": 2]]
        #expect(LanguageAssistance.completions(response, text: "pr", offset: 2).isEmpty)
    }

    @Test func rendersMarkupAndActiveSignatureParameterOffsets() throws {
        #expect(LanguageAssistance.documentation(["language": "go", "value": "func Add(a, b int) int"]) == "```go\nfunc Add(a, b int) int\n```")
        #expect(LanguageAssistance.documentation(["first", ["kind": "markdown", "value": "**second**"]]) == "first\n\n**second**")
        let value: JSONValue = ["activeParameter": 1, "signatures": [["label": "Add(a int, b int)", "parameters": [["label": [4, 9]], ["label": [11, 16]]], "documentation": ["kind": "markdown", "value": "Adds two values."]]]]
        let signature = try #require(LanguageAssistance.signature(value))
        #expect(signature.parameter == "b int")
        #expect(signature.documentation == "Adds two values.")
    }

    @Test func rejectsWorkspaceFileOperationsAndCombinesTextEdits() throws {
        let edit: JSONValue = ["range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 0]], "newText": "import"]
        let changes = try LanguageAssistance.textEdits(["changes": ["file:///main.go": [edit]], "documentChanges": [["textDocument": ["uri": "file:///main.go", "version": 2], "edits": [edit]]]])
        #expect(changes["file:///main.go"]?.count == 2)
        #expect(throws: AgentError.self) { try LanguageAssistance.textEdits(["documentChanges": [["kind": "delete", "uri": "file:///main.go"]]]) }
    }
}
