import Foundation

public enum CodeTokenKind: String, Sendable {
    case keyword, type, function, string, number, comment, property, variable, constant, attribute, punctuation, tag
}

public struct CodeToken: Sendable, Equatable {
    public var range: NSRange
    public var kind: CodeTokenKind
    public init(_ range: NSRange, _ kind: CodeTokenKind) { self.range = range; self.kind = kind }
}

/// A small lexical highlighter. Strings and comments are consumed as complete tokens,
/// so identifiers inside them can never be coloured as code. All offsets are UTF-16.
public enum CodeSyntax {
    public static func tokens(in text: String, path: String) -> [CodeToken] {
        if MarkdownParser.isMarkdown(path) { return markdownTokens(text) }
        var lexer = Lexer(text, path: path)
        return lexer.scan()
    }

    private static func markdownTokens(_ text: String) -> [CodeToken] {
        let rules: [(String, CodeTokenKind)] = [
            (#"(?ms)^ {0,3}(`{3,}|~{3,})[^\n]*\n.*?^ {0,3}\1[ \t]*(?=\n|$)"#, .string),
            (#"`+[^`\n]+`+"#, .string),
            (#"(?m)^ {0,3}#{1,6}[ \t]+.*$|^ {0,3}(?:={2,}|-{2,})[ \t]*$"#, .keyword),
            (#"!?\[[^\]\n]*\]\([^\n]*?\)"#, .function),
            (#"\*\*[^*\n]+\*\*|__[^_\n]+__"#, .keyword),
            (#"\*[^*\n]+\*|_[^_\n]+_"#, .type),
            (#"(?m)^[ \t]*(?:[-+*]|\d+\.)[ \t]+(?:\[[ xX]\])?"#, .punctuation),
            (#"(?m)^ {0,3}>.*$"#, .comment)
        ]
        let length = (text as NSString).length
        var occupied = IndexSet(), tokens: [CodeToken] = []
        for (pattern, kind) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: length)) {
                let range = match.range.location..<NSMaxRange(match.range)
                guard !occupied.intersects(integersIn: range) else { continue }
                occupied.insert(integersIn: range)
                tokens.append(CodeToken(match.range, kind))
            }
        }
        return tokens.sorted { $0.range.location < $1.range.location }
    }

    private struct Lexer {
        let source: NSString
        let units: [UInt16]
        let language: String
        let words: Set<String>
        let types: Set<String>
        let depth: Int
        var position = 0
        var result: [CodeToken] = []
        var previousWord = ""
        var previousSymbol: UInt16 = 0

        init(_ text: String, path: String, depth: Int = 0) {
            source = text as NSString; units = Array(text.utf16)
            self.depth = depth
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            switch ext {
            case "go", "mod": language = "go"
            case "swift", "swiftinterface": language = "swift"
            case "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts": language = "javascript"
            case "py", "pyi": language = "python"
            case "rs": language = "rust"
            case "proto": language = "proto"
            case "graphql", "gql", "graphqls": language = "graphql"
            case "json", "jsonc": language = "json"
            case "yaml", "yml", "toml", "ini", "conf": language = "config"
            case "sh", "bash", "zsh", "fish": language = "shell"
            case "rb", "rake": language = "ruby"
            case "sql": language = "sql"
            case "txt", "log", "md", "markdown", "csv", "tsv": language = "plain"
            case "html", "htm", "xml", "svg": language = "markup"
            case "css", "scss", "sass", "less": language = "css"
            default: language = "c"
            }
            words = Set((Self.keywords[language] ?? Self.keywords["c"]!).split(separator: " ").map(String.init))
            types = Set((Self.builtinTypes[language] ?? "").split(separator: " ").map(String.init))
        }

        func at(_ index: Int) -> UInt16 { units.indices.contains(index) ? units[index] : 0 }
        func begins(_ value: String) -> Bool {
            let expected = Array(value.utf16)
            return position + expected.count <= units.count && units[position..<(position + expected.count)].elementsEqual(expected)
        }
        func wordStart(_ c: UInt16) -> Bool { c == 95 || c >= 128 || (65...90).contains(c) || (97...122).contains(c) }
        func wordPart(_ c: UInt16) -> Bool { wordStart(c) || (48...57).contains(c) }
        func skipSpace(_ start: Int) -> Int {
            var index = start
            while [UInt16(9), 10, 13, 32].contains(at(index)) { index += 1 }
            return index
        }
        mutating func emit(_ start: Int, _ kind: CodeTokenKind) {
            guard position > start else { return }
            result.append(CodeToken(NSRange(location: start, length: position - start), kind))
        }

        mutating func scan() -> [CodeToken] {
            if language == "plain" { return [] }
            if language == "markup" { return markup() }
            while position < units.count {
                if position % 1024 == 0 && Task.isCancelled { return [] }
                let start = position, c = at(position)
                if [UInt16(9), 10, 13, 32].contains(c) { position += 1; continue }
                let hashComment = ["python", "config", "shell", "graphql", "ruby"].contains(language)
                if (hashComment && c == 35) || (language == "sql" && begins("--")) || (begins("//") && !["config", "shell", "python", "graphql", "ruby", "sql"].contains(language)) {
                    while position < units.count && at(position) != 10 && at(position) != 13 { position += 1 }
                    emit(start, .comment); continue
                }
                if begins("/*") && !["python", "config", "shell", "graphql"].contains(language) {
                    position += 2
                    var depth = 1
                    while position < units.count && depth > 0 {
                        if begins("/*") && ["swift", "rust"].contains(language) { depth += 1; position += 2 }
                        else if begins("*/") { depth -= 1; position += 2 }
                        else { position += 1 }
                    }
                    emit(start, .comment); continue
                }
                if c == 34 || c == 39 || c == 96 {
                    consumeString(quote: c)
                    if language == "javascript" && c == 96 && depth < 8 { emitTemplate(start) }
                    else { emit(start, (language == "json" || language == "config") && at(skipSpace(position)) == 58 ? .property : .string) }
                    continue
                }
                if language == "swift" && c == 35 {
                    var hashes = 0
                    while at(position + hashes) == 35 { hashes += 1 }
                    if at(position + hashes) == 34 {
                        position += hashes; consumeString(quote: 34, rawHashes: hashes); emit(start, .string); continue
                    }
                }
                if language == "python", [UInt16(102), 114, 98, 117, 70, 82, 66, 85].contains(c) {
                    var end = position
                    while end < position + 3 && [UInt16(102), 114, 98, 117, 70, 82, 66, 85].contains(at(end)) { end += 1 }
                    if at(end) == 34 || at(end) == 39 { position = end; consumeString(quote: at(end)); emit(start, .string); continue }
                }
                if (48...57).contains(c) || (c == 46 && (48...57).contains(at(position + 1))) {
                    position += 1
                    while position < units.count {
                        let next = at(position)
                        if (48...57).contains(next) || next == 95 || (65...70).contains(next) || (97...102).contains(next) || [UInt16(120), 88, 111, 79, 98, 66].contains(next) { position += 1 }
                        else if next == 46 && at(position + 1) != 46 && (48...57).contains(at(position + 1)) { position += 1 }
                        else if (next == 43 || next == 45) && [UInt16(101), 69].contains(at(position - 1)) { position += 1 }
                        else { break }
                    }
                    emit(start, .number); previousSymbol = 0; continue
                }
                if language == "css", c == 35 {
                    position += 1
                    while (48...57).contains(at(position)) || (65...70).contains(at(position)) || (97...102).contains(at(position)) { position += 1 }
                    if position > start + 1 { emit(start, .number); continue }
                    position = start
                }
                if c == 64 || (c == 35 && language == "swift") {
                    position += 1
                    while wordPart(at(position)) { position += 1 }
                    emit(start, .attribute); continue
                }
                if c == 36 && ["graphql", "shell", "javascript"].contains(language) {
                    position += 1
                    while wordPart(at(position)) { position += 1 }
                    emit(start, .variable); continue
                }
                if wordStart(c) {
                    position += 1
                    while wordPart(at(position)) { position += 1 }
                    let word = source.substring(with: NSRange(location: start, length: position - start))
                    let next = at(skipSpace(position))
                    let kind: CodeTokenKind
                    if ["true", "false", "nil", "null", "None", "True", "False", "undefined", "NULL"].contains(word) { kind = .constant }
                    else if words.contains(language == "sql" ? word.uppercased() : word) { kind = .keyword }
                    else if ["func", "function", "def", "fn"].contains(previousWord) { kind = .function }
                    else if language == "config" && (next == 58 || next == 61) { kind = .property }
                    else if language == "css" && next == 58 { kind = .property }
                    else if next == 40 && !types.contains(word) { kind = .function }
                    else if previousSymbol == 46 { kind = .property }
                    else if types.contains(word) || (65...90).contains(c) && !word.allSatisfy({ !$0.isLetter || $0.isUppercase }) { kind = .type }
                    else if word.count > 1 && word.allSatisfy({ !$0.isLetter || $0.isUppercase }) && word.contains(where: \.isLetter) { kind = .constant }
                    else if language == "graphql" { kind = .property }
                    else { kind = .variable }
                    emit(start, kind); previousWord = word; previousSymbol = 0; continue
                }
                position += 1
                emit(start, .punctuation)
                previousSymbol = c
                if c != 46 { previousWord = "" }
            }
            return result
        }

        mutating func consumeString(quote: UInt16, rawHashes: Int = 0) {
            let triple = at(position + 1) == quote && at(position + 2) == quote && ["python", "swift", "graphql", "config"].contains(language)
            let width = triple ? 3 : 1
            position += width
            while position < units.count {
                if at(position) == quote && (!triple || (at(position + 1) == quote && at(position + 2) == quote)) {
                    if rawHashes > 0 && !(0..<rawHashes).allSatisfy({ at(position + width + $0) == 35 }) { position += 1; continue }
                    position += width + rawHashes; return
                }
                if at(position) == 92 && (quote != 96 || language == "javascript") && rawHashes == 0 { position = min(units.count, position + 2) }
                else { position += 1 }
            }
        }

        mutating func emitTemplate(_ start: Int) {
            let end = position
            var cursor = start + 1, segment = start
            while cursor + 1 < end {
                if at(cursor) == 92 { cursor += 2; continue }
                guard at(cursor) == 36 && at(cursor + 1) == 123 else { cursor += 1; continue }
                var close = cursor + 2, braces = 1, quote: UInt16?
                while close < end && braces > 0 {
                    let c = at(close)
                    if let current = quote {
                        if c == 92 { close += 2; continue }
                        if c == current { quote = nil }
                    } else if c == 34 || c == 39 || c == 96 { quote = c }
                    else if c == 123 { braces += 1 }
                    else if c == 125 { braces -= 1 }
                    if braces > 0 { close += 1 }
                }
                guard braces == 0 else { break }
                if segment < cursor { result.append(CodeToken(NSRange(location: segment, length: cursor - segment), .string)) }
                result.append(CodeToken(NSRange(location: cursor, length: 2), .punctuation))
                var expression = Lexer(source.substring(with: NSRange(location: cursor + 2, length: close - cursor - 2)), path: "expression.js", depth: depth + 1)
                result += expression.scan().map { CodeToken(NSRange(location: cursor + 2 + $0.range.location, length: $0.range.length), $0.kind) }
                result.append(CodeToken(NSRange(location: close, length: 1), .punctuation))
                cursor = close + 1; segment = cursor
            }
            if segment < end { result.append(CodeToken(NSRange(location: segment, length: end - segment), .string)) }
        }

        mutating func markup() -> [CodeToken] {
            var insideTag = false, expectsTag = false
            var tag = "", closing = false
            while position < units.count {
                if position % 1024 == 0 && Task.isCancelled { return [] }
                let start = position, c = at(position)
                if begins("<!--") {
                    position += 4
                    while position < units.count && !begins("-->") { position += 1 }
                    position = min(units.count, position + 3); emit(start, .comment); continue
                }
                if c == 60 { insideTag = true; expectsTag = true; tag = ""; closing = at(position + 1) == 47; position += 1; emit(start, .punctuation); continue }
                if c == 62 {
                    insideTag = false; position += 1; emit(start, .punctuation)
                    if !closing && ["script", "style"].contains(tag) {
                        let range = source.range(of: "</" + tag, options: .caseInsensitive, range: NSRange(location: position, length: units.count - position))
                        let end = range.location == NSNotFound ? units.count : range.location
                        let embedded = source.substring(with: NSRange(location: position, length: end - position))
                        let tokens = CodeSyntax.tokens(in: embedded, path: tag == "script" ? "embedded.js" : "embedded.css")
                        result += tokens.map { CodeToken(NSRange(location: position + $0.range.location, length: $0.range.length), $0.kind) }
                        position = end
                    }
                    continue
                }
                if !insideTag { position += 1; continue }
                if c == 34 || c == 39 { consumeString(quote: c); emit(start, .string); continue }
                if wordStart(c) {
                    position += 1
                    while wordPart(at(position)) || [UInt16(45), 58].contains(at(position)) { position += 1 }
                    if expectsTag { tag = source.substring(with: NSRange(location: start, length: position - start)).lowercased() }
                    emit(start, expectsTag ? .tag : .attribute); expectsTag = false; continue
                }
                position += 1
                if ![UInt16(32), 9, 10, 13].contains(c) { emit(start, .punctuation) }
            }
            return result
        }

        private static let keywords = [
            "go": "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var module require replace exclude retract toolchain",
            "swift": "actor as associatedtype async await borrowing break case catch class consuming continue convenience default defer deinit didSet distributed do dynamic else enum extension fallthrough fileprivate final for func get guard if import in indirect infix init inout internal is isolated lazy let macro mutating nonisolated nonmutating open operator optional override package postfix precedencegroup prefix private protocol public repeat required rethrows return self Self set some static struct subscript super switch throws throw try typealias unowned var weak where while willSet any",
            "javascript": "abstract as async await break case catch class const continue debugger declare default delete do else enum export extends finally for from function get if implements import in infer instanceof interface keyof let namespace new of package private protected public readonly return satisfies set static super switch this throw try type typeof var void while with yield",
            "python": "and as assert async await break case class continue def del elif else except finally for from global if import in is lambda match nonlocal not or pass raise return try while with yield",
            "rust": "as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type union unsafe use where while",
            "proto": "syntax edition package option import public weak message enum service rpc returns stream repeated optional required oneof reserved extensions extend map group to max",
            "graphql": "query mutation subscription fragment on schema type input enum interface union scalar extend implements directive repeatable",
            "json": "", "config": "", "shell": "if then else elif fi for in do done case esac while until function select return export local readonly declare unset source alias exit",
            "ruby": "alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield",
            "sql": "SELECT FROM WHERE INSERT INTO UPDATE DELETE CREATE ALTER DROP TABLE INDEX VIEW AS JOIN LEFT RIGHT INNER OUTER ON GROUP BY ORDER HAVING LIMIT OFFSET DISTINCT UNION ALL VALUES SET AND OR NOT IS IN EXISTS NULL CASE WHEN THEN ELSE END ASC DESC RETURNING WITH PRIMARY KEY REFERENCES BEGIN COMMIT ROLLBACK",
            "css": "important inherit initial unset none auto",
            "markup": "",
            "c": "abstract auto bool break case catch char class const constexpr continue default delete do double else enum explicit extern final float for friend goto if import inline int interface long namespace new noexcept operator override package private protected public register return short signed sizeof static struct super switch template this throw try typedef typename union unsigned using virtual void volatile while",
        ]
        private static let builtinTypes = [
            "go": "any bool byte comparable complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr",
            "swift": "String Int Double Float Bool Character Void Any Never Optional Array Dictionary Set Result Error UInt Data URL UUID",
            "javascript": "any unknown number string boolean symbol bigint never object Promise Array Record Partial Pick Omit Readonly Map Set Date Error",
            "python": "int float str bool bytes list dict tuple set object type complex",
            "rust": "bool char str String usize isize u8 u16 u32 u64 u128 i8 i16 i32 i64 i128 f32 f64 Option Result Vec Box",
            "proto": "double float int32 int64 uint32 uint64 sint32 sint64 fixed32 fixed64 sfixed32 sfixed64 bool string bytes",
            "graphql": "ID Int Float String Boolean",
        ]
    }
}
