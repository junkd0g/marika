import Foundation
import Testing
@testable import MarikaCore

struct CodeSyntaxTests {
    private func classified(_ source: String, _ path: String) -> [(String, CodeTokenKind)] {
        CodeSyntax.tokens(in: source, path: path).map { ((source as NSString).substring(with: $0.range), $0.kind) }
    }
    @Test func goSeparatesFunctionsTypesFieldsAndConstants() {
        let code = "func Fetch(ctx context.Context) (*User, error) { return api.Load(42, true) }"
        let tokens = classified(code, "handler.go")
        #expect(tokens.contains { $0.0 == "func" && $0.1 == .keyword })
        #expect(tokens.contains { $0.0 == "Fetch" && $0.1 == .function })
        #expect(tokens.contains { $0.0 == "User" && $0.1 == .type })
        #expect(tokens.contains { $0.0 == "error" && $0.1 == .type })
        #expect(tokens.contains { $0.0 == "Load" && $0.1 == .function })
        #expect(tokens.contains { $0.0 == "42" && $0.1 == .number })
        #expect(tokens.contains { $0.0 == "true" && $0.1 == .constant })
    }
    @Test func commentsAndStringsCannotProduceCodeTokens() {
        let source = "// func Fake() 99\nvar message = `func Fake()\nreturn 12`\n/* if \"string\" */"
        let tokens = classified(source, "main.go")
        #expect(tokens.filter { $0.1 == .comment }.count == 2)
        #expect(tokens.contains { $0.0 == "`func Fake()\nreturn 12`" && $0.1 == .string })
        #expect(!tokens.contains { $0.0 == "Fake" || $0.0 == "99" || $0.0 == "return" })
    }
    @Test func eachLanguageUsesItsOwnKeywordsAndMultilineRules() {
        let swift = classified("@MainActor final class User { let name: String = #\"hello\"# }", "User.swift")
        #expect(swift.contains { $0.0 == "@MainActor" && $0.1 == .attribute })
        #expect(swift.contains { $0.0 == "String" && $0.1 == .type })
        #expect(swift.contains { $0.0 == "#\"hello\"#" && $0.1 == .string })
        let python = classified("def load(user: str):\n    \"\"\"class False 123\"\"\"\n    return True # result", "load.py")
        #expect(python.contains { $0.0 == "load" && $0.1 == .function })
        #expect(python.contains { $0.0 == "\"\"\"class False 123\"\"\"" && $0.1 == .string })
        #expect(!classified("let value = 1", "a.go").contains { $0.0 == "let" && $0.1 == .keyword })
    }
    @Test func jsonKeysDifferFromStringValuesAndMarkupEmbedsCode() {
        let json = classified(#"{"name": "hello", "enabled": true}"#, "config.json")
        #expect(json.contains { $0.0 == "\"name\"" && $0.1 == .property })
        #expect(json.contains { $0.0 == "\"hello\"" && $0.1 == .string })
        let html = classified("<button class=\"primary\">Go</button><script>const x = fetch(12)</script>", "index.html")
        #expect(html.contains { $0.0 == "button" && $0.1 == .tag })
        #expect(html.contains { $0.0 == "class" && $0.1 == .attribute })
        #expect(html.contains { $0.0 == "const" && $0.1 == .keyword })
        #expect(html.contains { $0.0 == "fetch" && $0.1 == .function })
    }
    @Test func protobufGraphqlAndNestedCommentsAreRecognized() {
        let proto = classified("message User { string name = 1; }", "user.proto")
        #expect(proto.contains { $0.0 == "message" && $0.1 == .keyword })
        #expect(proto.contains { $0.0 == "string" && $0.1 == .type })
        let query = classified("query User($id: ID!) { user(id: $id) { name } } # note", "query.graphql")
        #expect(query.contains { $0.0 == "query" && $0.1 == .keyword })
        #expect(query.contains { $0.0 == "$id" && $0.1 == .variable })
        let nested = classified("/* outer /* inner */ outer */ let value = 1", "file.swift")
        #expect(nested.first?.0 == "/* outer /* inner */ outer */")
        #expect(nested.first?.1 == .comment)
    }
    @Test func unicodeOffsetsAndIncompleteEditsRemainSafe() {
        for source in ["let 🦊 = \"😄\"", "var x = \"unfinished", "/* unfinished", "func x(", "<script>let a = 1"] {
            let path = source.hasPrefix("<") ? "index.html" : "sample.swift"
            let tokens = CodeSyntax.tokens(in: source, path: path)
            var end = 0
            for token in tokens {
                #expect(token.range.location >= end)
                #expect(NSMaxRange(token.range) <= (source as NSString).length)
                #expect(token.range.length > 0)
                end = NSMaxRange(token.range)
            }
        }
        #expect(CodeSyntax.tokens(in: "plain words in a note", path: "notes.txt").isEmpty)
    }
    @Test func templateExpressionsAndEscapesKeepTheirOwnColours() {
        let source = "const message = `hello ${user.name}: ${format(42)} \\`done\\``"
        let tokens = classified(source, "app.ts")
        #expect(tokens.contains { $0.0 == "user" && $0.1 == .variable })
        #expect(tokens.contains { $0.0 == "name" && $0.1 == .property })
        #expect(tokens.contains { $0.0 == "format" && $0.1 == .function })
        #expect(tokens.contains { $0.0.contains("done") && $0.1 == .string })
        let ranges = CodeSyntax.tokens(in: source, path: "app.ts").map(\.range)
        for index in ranges.indices.dropFirst() { #expect(NSMaxRange(ranges[index - 1]) <= ranges[index].location) }
    }
}
