import Foundation

public struct ToolContext: Sendable {
    public var root: URL
    public var environment: [String: String]
    public var runtime: WorkspaceRuntime?
    public init(root: URL, environment: [String: String], runtime: WorkspaceRuntime? = nil) { self.root = root; self.environment = environment; self.runtime = runtime }
    public func invocation(_ command: String, arguments: [String] = []) throws -> (URL, [String]) {
        if let runtime { return try runtime.invocation(([command] + arguments).map(WorkspaceRuntime.quote).joined(separator: " "), environment: environment) }
        guard let executable = command.hasPrefix("/") ? URL(fileURLWithPath: command) : ShellEnvironment.locate(command, in: environment) else {
            throw AgentError.launchFailed("Install \(command) or configure its path in Editor extensions.")
        }
        return (executable, arguments)
    }
    public func run(_ command: String, arguments: [String] = [], timeout: Double = 120) async throws -> CommandResult {
        let (executable, args) = try invocation(command, arguments: arguments)
        return try await Command.run(executable, args, workingDirectory: root, environment: environment, timeout: timeout, outputLimit: 8_000_000)
    }
}

public struct ProjectTest: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var target: String
    public var framework: String
    public init(name: String, target: String, framework: String) { id = framework + ":" + target + ":" + name; self.name = name; self.target = target; self.framework = framework }
}
public struct TestExecution: Sendable {
    public var statuses: [String: String]
    public var output: String
    public var coverage: [String: [Int: Bool]]
    public var succeeded: Bool
}
public enum ProjectTests {
    public static func discover(context: ToolContext, framework: String) async throws -> [ProjectTest] {
        let result: CommandResult
        switch framework {
        case "Go": result = try await context.run("go", arguments: ["test", "-json", "-list", ".", "./..."], timeout: 300)
        case "Swift": result = try await context.run("swift", arguments: ["test", "list"], timeout: 300)
        default: result = try await context.run("python3", arguments: ["-m", "pytest", "--collect-only", "-q"], timeout: 120)
        }
        guard result.succeeded else { throw AgentError.launchFailed(String((result.errorOutput + result.output).suffix(8000))) }
        return parseDiscovery(result.output, framework: framework)
    }
    public static func parseDiscovery(_ text: String, framework: String) -> [ProjectTest] {
        var tests: [ProjectTest] = []
        for raw in text.components(separatedBy: "\n") {
            if framework == "Go", let json = try? JSONValue(parsing: Data(raw.utf8)), let package = json["Package"]?.string, let output = json["Output"]?.string {
                for name in output.split(separator: "\n").map(String.init) where name.hasPrefix("Test") || name.hasPrefix("Example") || name.hasPrefix("Fuzz") {
                    tests.append(ProjectTest(name: name, target: package, framework: framework))
                }
            } else if framework == "Swift", raw.contains("/"), !raw.contains(" ") {
                tests.append(ProjectTest(name: raw, target: raw, framework: framework))
            } else if framework == "Python", raw.contains("::"), !raw.hasPrefix(" ") {
                tests.append(ProjectTest(name: raw, target: raw, framework: framework))
            }
        }
        return Array(Set(tests)).sorted { $0.id < $1.id }
    }
    public static func run(context: ToolContext, framework: String, test: ProjectTest? = nil, targets: [String]? = nil) async throws -> TestExecution {
        let result: CommandResult
        if framework == "Go" {
            let args = ["go", "test", "-json", "-count=1", "-coverprofile=\"$coverage\""]
            let filter = test.map { " -run " + WorkspaceRuntime.quote("^" + NSRegularExpression.escapedPattern(for: $0.name) + "$") } ?? ""
            let packages = test.map { [$0.target] } ?? targets.flatMap { $0.isEmpty ? nil : $0 } ?? ["./..."]
            let script = "coverage=$(mktemp); " + args.prefix(4).map(WorkspaceRuntime.quote).joined(separator: " ") + " -coverprofile=\"$coverage\"" + filter + " " + packages.map(WorkspaceRuntime.quote).joined(separator: " ") + "; status=$?; printf '\\nMARIKA_COVERAGE\\n'; cat \"$coverage\"; rm -f \"$coverage\"; exit \"$status\""
            result = try await context.run("sh", arguments: ["-c", script], timeout: 600)
        } else if framework == "Swift" {
            result = try await context.run("swift", arguments: ["test", "--enable-code-coverage"] + (test.map { ["--filter", $0.target] } ?? []), timeout: 600)
        } else {
            result = try await context.run("python3", arguments: ["-m", "pytest", "-v"] + (test.map { [$0.target] } ?? []), timeout: 600)
        }
        var statuses: [String: String] = [:]
        for line in result.output.components(separatedBy: "\n") {
            if framework == "Go", let json = try? JSONValue(parsing: Data(line.utf8)), let name = json["Test"]?.string, let package = json["Package"]?.string,
               let action = json["Action"]?.string, ["pass", "fail", "skip", "run"].contains(action) {
                statuses[ProjectTest(name: name, target: package, framework: framework).id] = action
            }
        }
        if let test, statuses[test.id] == nil { statuses[test.id] = result.succeeded ? "pass" : "fail" }
        let sections = result.output.components(separatedBy: "MARIKA_COVERAGE\n")
        let coverage = sections.count > 1 ? parseCoverage(sections.last ?? "") : [:]
        let display = framework == "Go" ? sections[0].components(separatedBy: "\n").compactMap { line -> String? in
            if let event = try? JSONValue(parsing: Data(line.utf8)) { return event["Output"]?.string }
            return line.isEmpty ? nil : line + "\n"
        }.joined() : sections[0]
        return TestExecution(statuses: statuses, output: String((display + "\n" + result.errorOutput).suffix(64_000)), coverage: coverage, succeeded: result.succeeded)
    }
    public static func parseCoverage(_ text: String) -> [String: [Int: Bool]] {
        var coverage: [String: [Int: Bool]] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("mode:") {
            let fields = line.split(separator: " ")
            guard fields.count == 3, let colon = fields[0].lastIndex(of: ":"), let count = Int(fields[2]) else { continue }
            let path = String(fields[0][..<colon]), positions = fields[0][fields[0].index(after: colon)...].split(separator: ",")
            guard positions.count == 2, let start = Int(positions[0].split(separator: ".")[0]), let end = Int(positions[1].split(separator: ".")[0]), end >= start, end - start < 100_000 else { continue }
            for number in start...end { coverage[path, default: [:]][number] = (coverage[path]?[number] ?? false) || count > 0 }
        }
        return coverage
    }
}
