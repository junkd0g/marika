import Foundation
import Observation

@MainActor @Observable
public final class ProjectPreview {
    public enum State: String { case stopped, starting, running, failed }
    public private(set) var state: State = .stopped
    public private(set) var logs = ""
    public private(set) var address: URL?
    public private(set) var error: String?
    public private(set) var portConflict: Int?
    public var isActive: Bool { state == .starting || state == .running }
    @ObservationIgnored public var onReady: ((URL) -> Void)?
    @ObservationIgnored private var process: ProcessGroup?
    @ObservationIgnored private var probe: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    private let startupTimeout: Duration

    public init(startupTimeout: Duration = .seconds(30)) { self.startupTimeout = startupTimeout }
    public nonisolated static func detect(at root: URL) -> PreviewConfiguration? {
        let fm = FileManager.default
        let package = root.appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: package),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = json["scripts"] as? [String: String],
           let name = ["dev", "start", "serve"].first(where: { scripts[$0] != nil }) {
            let manager = fm.fileExists(atPath: root.appendingPathComponent("pnpm-lock.yaml").path) ? "pnpm" :
                fm.fileExists(atPath: root.appendingPathComponent("yarn.lock").path) ? "yarn" :
                fm.fileExists(atPath: root.appendingPathComponent("bun.lockb").path) || fm.fileExists(atPath: root.appendingPathComponent("bun.lock").path) ? "bun" : "npm"
            let script = scripts[name] ?? ""
            let port = script.contains("vite") ? 5173 : script.contains("astro") ? 4321 : 3000
            return PreviewConfiguration(command: "\(manager) run \(name)", address: "http://localhost:\(port)")
        }
        if fm.fileExists(atPath: root.appendingPathComponent("manage.py").path) {
            return PreviewConfiguration(command: "python3 manage.py runserver 127.0.0.1:8000", address: "http://127.0.0.1:8000")
        }
        if fm.fileExists(atPath: root.appendingPathComponent("index.html").path) {
            return PreviewConfiguration(command: "python3 -m http.server 8000 --bind 127.0.0.1", address: "http://127.0.0.1:8000")
        }
        return nil
    }

    public func start(_ configuration: PreviewConfiguration, at root: URL, environment: [String: String]) {
        guard !isActive else { return }
        process?.stop()
        generation = UUID(); let current = generation
        logs = "$ " + configuration.command + "\n"; error = nil; address = nil; portConflict = nil
        guard !configuration.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: configuration.address), Self.isLocal(url), url.user == nil, url.password == nil else {
            state = .failed; error = "Enter a run command and a local HTTP or HTTPS preview URL."; return
        }
        address = url
        guard !PreviewPort.isOccupied(url) else {
            portConflict = url.port ?? (url.scheme == "https" ? 443 : 80)
            state = .failed
            error = "Port \(portConflict!) is already in use. Stop the other server, or change the port in both the command and preview URL."
            return
        }
        state = .starting
        var env = environment; env["NO_COLOR"] = "1"; env["PYTHONUNBUFFERED"] = "1"; env["BROWSER"] = "none"
        let child = ProcessGroup(output: { [weak self] data in
            Task { @MainActor in self?.append(data, generation: current) }
        }, completion: { [weak self] status in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.probe?.cancel()
                if self.state != .stopped && self.state != .failed {
                    let neverReady = self.state == .starting
                    self.state = status == 0 && !neverReady ? .stopped : .failed
                    if self.error == nil {
                        self.error = neverReady ? "The preview command exited before the server was ready (exit \(status)). Check the command and logs."
                            : status == 0 ? nil : "Preview stopped with exit code \(status). Check the logs below."
                    }
                }
            }
        })
        process = child
        do {
            try child.start(command: configuration.command, directory: root, environment: env)
            watch(url, generation: current)
        } catch { self.error = error.localizedDescription; state = .failed; process = nil }
    }

    public func stop() {
        state = .stopped; generation = UUID(); probe?.cancel(); process?.stop(); process = nil
        error = nil; portConflict = nil
    }

    private func append(_ data: Data, generation current: UUID) {
        guard generation == current else { return }
        logs += String(decoding: data, as: UTF8.self).withoutTerminalCodes
        if logs.count > 80_000 { logs = String(logs.suffix(80_000)) }
        guard state == .starting else { return }
        if logs.localizedCaseInsensitiveContains("EADDRINUSE") || logs.localizedCaseInsensitiveContains("address already in use") {
            error = "The preview port became occupied during startup. Stop the other server, or change the port in the command and preview URL."
            state = .failed; probe?.cancel(); process?.stop(); process = nil
            return
        }
        if let url = Self.detectedAddress(in: logs), url != address { watch(url, generation: current) }
    }

    /// Console messages often wrap URLs in parentheses or quotes (including Python's
    /// http.server). Keep balanced path punctuation, but discard the surrounding prose.
    nonisolated static func detectedAddress(in logs: String) -> URL? {
        let pattern = #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::\]):[0-9]+(?:/[^\s\x1b]*)?"#
        guard let match = logs.range(of: pattern, options: .regularExpression) else { return nil }
        var value = String(logs[match])
        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        while let last = value.last {
            if ".,;>\"'".contains(last) { value.removeLast() }
            else if let opening = pairs[last], value.count(where: { $0 == last }) > value.count(where: { $0 == opening }) { value.removeLast() }
            else { break }
        }
        return URL(string: value.replacingOccurrences(of: "0.0.0.0", with: "127.0.0.1").replacingOccurrences(of: "[::]", with: "localhost"))
    }

    private static func isLocal(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme ?? "") && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host ?? "")
    }
    private func watch(_ url: URL, generation current: UUID) {
        address = url; probe?.cancel()
        let deadline = ContinuousClock.now + startupTimeout
        probe = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            while ContinuousClock.now < deadline {
                guard !Task.isCancelled, let self, self.generation == current, self.isActive else { return }
                var request = URLRequest(url: url); request.timeoutInterval = 1
                if let (_, response) = try? await URLSession.shared.data(for: request), response is HTTPURLResponse {
                    guard !Task.isCancelled, self.generation == current, self.isActive else { return }
                    self.state = .running; self.onReady?(url); return
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard let self, self.generation == current, self.state == .starting else { return }
            self.error = "The command is running, but the preview URL is not responding. Check its address and logs."
            self.state = .failed; self.process?.stop(); self.process = nil
        }
    }
}
