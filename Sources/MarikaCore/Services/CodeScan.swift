import Foundation

public struct CodeScan: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public var provider: AgentKind?
    public var modelID: String?
    public var inventory: ScanInventory?
    public var review: ScanReview?
    public var analysis: String?
    public var agentSessionID: UUID?
    public let files: Int
    public let linesByLanguage: [String: Int]
    public let markerLines: Int
    public let skipped: Int
    public let limited: Bool
    public var lines: Int { linesByLanguage.values.reduce(0, +) }

    private static let languages = [
        "swift": "Swift", "m": "Objective-C", "mm": "Objective-C++", "h": "C/C++ headers",
        "c": "C", "cpp": "C++", "cc": "C++", "hpp": "C++", "rs": "Rust", "go": "Go",
        "js": "JavaScript", "jsx": "JavaScript", "mjs": "JavaScript", "cjs": "JavaScript",
        "ts": "TypeScript", "tsx": "TypeScript", "py": "Python", "rb": "Ruby", "php": "PHP",
        "java": "Java", "kt": "Kotlin", "cs": "C#", "html": "HTML", "css": "CSS",
        "scss": "SCSS", "vue": "Vue", "svelte": "Svelte", "sh": "Shell", "zsh": "Shell",
        "bash": "Shell", "sql": "SQL", "dart": "Dart", "scala": "Scala", "lua": "Lua"
    ]

    public static func run(at root: URL) async throws -> CodeScan {
        let reader = ProjectFiles(root: root)
        let paths = try await reader.filePaths(limit: 20_001)
        var counts: [String: Int] = [:]
        var files = 0, markers = 0, skipped = 0
        var inventory = ScanInventory(sourceLines: 0, testLines: 0, testFiles: 0, generatedLines: 0,
                                      generatedFiles: 0, excludedFiles: 0, modules: [:], largestFiles: [], markers: [])
        for path in paths.prefix(20_000) {
            try Task.checkCancellation()
            guard let language = languages[(path as NSString).pathExtension.lowercased()] else { continue }
            let parts = path.lowercased().split(separator: "/").map(String.init)
            if !Set(parts.dropLast()).isDisjoint(with: ["vendor", ".venv", "venv", "pods", "carthage", "dist", "build", "target", ".next", "coverage", ".cache"]) {
                inventory.excludedFiles += 1
                continue
            }
            guard let source = try? await reader.read(path) else { skipped += 1; continue }
            let name = parts.last ?? ""
            let header = String(source.text.prefix(2500)).lowercased()
            let generatedHeader = header.range(of: #"(?m)^\s*(?://|#|/\*|\*|<!--)[^\n]*(?:code generated|automatically generated|auto-generated|@generated)"#, options: .regularExpression) != nil
            let generated = generatedHeader ||
                name.hasSuffix(".pb.go") || name.hasPrefix("mock_") ||
                !Set(parts.dropLast()).isDisjoint(with: ["generated", "mocks", "__generated__"])
            let isTest = name.hasSuffix("_test.go") || name.hasPrefix("test_") || name.contains(".test.") ||
                name.contains(".spec.") || name.hasSuffix("tests.swift") ||
                !Set(parts.dropLast()).isDisjoint(with: ["tests", "test", "__tests__", "spec", "specs"])
            var lines = 0
            source.text.enumerateLines { line, _ in
                lines += 1
                if !generated && (line.contains("TODO") || line.contains("FIXME")) {
                    markers += 1
                    if inventory.markers.count < 20 {
                        inventory.markers.append(ScanMarker(path: path, line: lines, text: String(line.trimmingCharacters(in: .whitespaces).prefix(220))))
                    }
                }
            }
            if generated {
                inventory.generatedFiles += 1
                inventory.generatedLines += lines
                continue
            }
            files += 1
            counts[language, default: 0] += lines
            if isTest {
                inventory.testFiles += 1
                inventory.testLines += lines
            } else {
                inventory.sourceLines += lines
                let module = parts.count > 2 ? parts.prefix(2).joined(separator: "/") : parts.count > 1 ? parts[0] : "Root"
                inventory.modules[module, default: 0] += lines
                inventory.largestFiles.append(ScanFile(path: path, lines: lines))
                inventory.largestFiles.sort { $0.lines == $1.lines ? $0.path < $1.path : $0.lines > $1.lines }
                inventory.largestFiles = Array(inventory.largestFiles.prefix(12))
            }
        }
        return CodeScan(id: UUID(), date: Date(), inventory: inventory, files: files, linesByLanguage: counts,
                        markerLines: markers, skipped: skipped, limited: paths.count > 20_000)
    }
}
