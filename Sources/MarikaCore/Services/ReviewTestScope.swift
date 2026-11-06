import Foundation

public struct ReviewTestScope: Sendable, Equatable {
    public var framework: String
    public var targets: [String]
    public var command: [String]? = nil
    public var title: String { command?.joined(separator: " ") ?? (framework == "Go" ? targets.joined(separator: ", ") : "All \(framework) tests") }

    public static func resolve(paths: [String], root: URL) -> Self {
        let files = FileManager.default
        if files.fileExists(atPath: root.appendingPathComponent("go.mod").path) || paths.contains(where: { $0.hasSuffix(".go") }) {
            let goFiles = paths.filter { $0.hasSuffix(".go") }
            let targets = goFiles.map { path -> String in
                let parent = (path as NSString).deletingLastPathComponent
                return parent.isEmpty ? "." : "./" + parent
            }
            return Self(framework: "Go", targets: targets.isEmpty || paths.contains("go.mod") || paths.contains("go.sum") ? ["./..."] : Array(Set(targets)).sorted())
        }
        if files.fileExists(atPath: root.appendingPathComponent("Package.swift").path) { return Self(framework: "Swift", targets: []) }
        if files.fileExists(atPath: root.appendingPathComponent("Cargo.toml").path) { return Self(framework: "Rust", targets: [], command: ["cargo", "test"]) }
        if let data = try? Data(contentsOf: root.appendingPathComponent("package.json")),
           let json = try? JSONValue(parsing: data), let test = json["scripts"]?["test"]?.string, !test.isEmpty {
            let tool = files.fileExists(atPath: root.appendingPathComponent("pnpm-lock.yaml").path) ? "pnpm"
                : files.fileExists(atPath: root.appendingPathComponent("yarn.lock").path) ? "yarn"
                : files.fileExists(atPath: root.appendingPathComponent("bun.lock").path) || files.fileExists(atPath: root.appendingPathComponent("bun.lockb").path) ? "bun" : "npm"
            return Self(framework: "JavaScript", targets: [], command: [tool, "run", "test"])
        }
        return Self(framework: "Python", targets: [])
    }

    public func run(in context: ToolContext) async throws -> TestExecution {
        if let command, let executable = command.first {
            var context = context
            context.environment["CI"] = "1"
            let result = try await context.run(executable, arguments: Array(command.dropFirst()), timeout: 600)
            return TestExecution(statuses: [:], output: String((result.output + result.errorOutput).suffix(64_000)), coverage: [:], succeeded: result.succeeded)
        }
        return try await ProjectTests.run(context: context, framework: framework, targets: targets)
    }
}
