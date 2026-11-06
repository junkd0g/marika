import Foundation

/// The environment agents should run in.
///
/// An app launched from Finder or the Dock gets a bare environment with almost nothing on
/// `PATH`, so neither the agent CLIs nor the tools they call (node, git, gh, swift…) would be
/// found. This asks the user's login shell for its real environment once at launch.
public enum ShellEnvironment {
    /// System variables worth keeping. Everything else comes from the user's own shell
    /// profile, which keeps state from whatever launched this app out of the agent's
    /// environment.
    private static let inherited = [
        "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
        "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING", "COMMAND_MODE",
    ]
    private static let systemPath = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    private static let marker = "__MARIKA_ENV_BEGIN__"

    public static func capture(from base: [String: String] = ProcessInfo.processInfo.environment) async -> [String: String] {
        var seed = base.filter { inherited.contains($0.key) }
        seed["PATH"] = systemPath
        seed["TERM"] = "dumb"
        if seed["HOME"] == nil { seed["HOME"] = NSHomeDirectory() }

        let shell = seed["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let script = "printf '\(marker)\\0'; /usr/bin/env -0"
        guard
            let result = try? await Command.run(
                URL(fileURLWithPath: shell), ["-ilc", script], environment: seed, timeout: 8),
            let captured = parse(result.stdout), !captured.isEmpty
        else {
            return withFallbackPath(seed)
        }
        // Profiles should not be able to drop variables the system provided.
        return withFallbackPath(seed.merging(captured) { _, profile in profile })
    }

    /// Reads NUL-separated `KEY=value` entries after the marker. Interactive shells can print
    /// banners first, which the marker lets us skip.
    static func parse(_ data: Data) -> [String: String]? {
        guard let range = data.range(of: Data(marker.utf8)) else { return nil }
        var environment: [String: String] = [:]
        for entry in data[range.upperBound...].split(separator: 0) {
            guard let separator = entry.firstIndex(of: UInt8(ascii: "=")) else { continue }
            let key = String(decoding: entry[entry.startIndex..<separator], as: UTF8.self)
            let value = String(decoding: entry[entry.index(after: separator)...], as: UTF8.self)
            if !key.isEmpty { environment[key] = value }
        }
        return environment
    }

    private static func withFallbackPath(_ environment: [String: String]) -> [String: String] {
        var environment = environment
        let existing = (environment["PATH"] ?? systemPath).split(separator: ":").map(String.init)
        let missing = commonToolDirectories(home: environment["HOME"] ?? NSHomeDirectory())
            .filter { !existing.contains($0) }
        environment["PATH"] = (existing + missing).joined(separator: ":")
        return environment
    }

    static func commonToolDirectories(home: String) -> [String] {
        [
            "\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.volta/bin",
            "\(home)/.cargo/bin", "\(home)/go/bin",
        ]
    }

    /// Finds an executable on the environment's `PATH`.
    public static func locate(_ tool: String, in environment: [String: String]) -> URL? {
        let directories = (environment["PATH"] ?? systemPath).split(separator: ":").map(String.init)
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

/// Finds an agent's official command-line tool.
public enum AgentLocator {
    /// A CLI on `PATH` wins, because that is the one the user chose. Otherwise, Codex ships inside
    /// OpenAI's desktop app, which never puts it on `PATH`. Pass `appBundles` for copies installed
    /// somewhere unusual.
    public static func locate(_ agent: AgentKind, in environment: [String: String], appBundles: [URL] = []) -> URL? {
        if let found = ShellEnvironment.locate(agent.executableName, in: environment) { return found }
        guard agent == .codex else { return nil }

        let home = environment["HOME"] ?? NSHomeDirectory()
        let standard = ["/Applications", "\(home)/Applications"].flatMap { folder in
            ["ChatGPT.app", "Codex.app"].map { URL(fileURLWithPath: folder).appendingPathComponent($0) }
        }
        for bundle in appBundles + standard {
            for path in ["Contents/Resources/codex-cli/bin/codex", "Contents/Resources/codex"] {
                let candidate = bundle.appendingPathComponent(path)
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }
}

public enum FilePath {
    /// The file a link in agent output points at. Agents write links like
    /// `[a.py](/work/a.py:12)` or `[a.py](src/a.py#L12)`, with the position on the end.
    public static func linkTarget(_ url: URL, relativeTo root: URL?) -> URL? {
        guard url.scheme == nil || url.isFileURL else { return nil }
        var path = url.path(percentEncoded: false)
        if let position = path.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) {
            path.removeSubrange(position)
        }
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("~/") { return URL(fileURLWithPath: NSHomeDirectory() + path.dropFirst(1)) }
        return root?.appendingPathComponent(path)
    }

    /// The path with symlinks resolved, as agents report it. `URL.resolvingSymlinksInPath()`
    /// can't be used here because it strips the `/private` prefix back off.
    public static func resolved(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
