import Foundation
import Observation

/// The official CLI owns authentication in Terminal. Marika observes only its exit code
/// and verifies the account through the existing read-only status probe.
@MainActor @Observable public final class AgentSignIn {
    public enum Phase: Equatable, Sendable { case idle, waiting, checking, succeeded, failed }
    public private(set) var phase: Phase = .idle
    public private(set) var message: String?
    public var isPending: Bool { phase == .waiting || phase == .checking }
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var previousStatus: AgentStatus?
    @ObservationIgnored private var latestStatus: AgentStatus?
    @ObservationIgnored private var completedCode: Int?
    private let root: URL
    private let timeout: Duration
    private let pollInterval: Duration

    public init(root: URL = FileManager.default.temporaryDirectory, timeout: Duration = .seconds(300), pollInterval: Duration = .milliseconds(500)) {
        self.root = root; self.timeout = timeout; self.pollInterval = pollInterval
    }

    public func start(agent: AgentKind, executable: URL?, previousStatus: AgentStatus? = nil, open: (URL) -> Bool,
                      verify: @escaping @MainActor () async -> AgentStatus.Readiness) {
        guard !isPending else { return }
        generation = UUID(); let attempt = generation
        monitor?.cancel(); message = nil
        self.previousStatus = previousStatus; latestStatus = previousStatus; completedCode = nil
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            fail("Couldn't find the \(agent.shortName) CLI. Check its installation, then retry sign-in.")
            return
        }
        let folder = root.appendingPathComponent("Marika-sign-in-\(UUID())", isDirectory: true)
        let command = folder.appendingPathComponent("Sign In.command")
        let result = folder.appendingPathComponent("result")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        #!/bin/zsh -l
        \(quote(executable.path)) \(agent == .claude ? "auth login" : "login")
        MARIKA_LOGIN_RESULT=$?
        umask 077
        printf '%s\\n' "$MARIKA_LOGIN_RESULT" > \(quote(result.path))
        echo
        echo "Return to Marika to check the connection. You can close this window."
        exit "$MARIKA_LOGIN_RESULT"

        """
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try script.write(to: command, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
            guard open(command) else {
                try? FileManager.default.removeItem(at: folder)
                fail("Couldn't open Terminal for sign-in. Retry Sign In to try again.")
                return
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            fail("Couldn't prepare sign-in. Retry Sign In to try again. \(error.localizedDescription)")
            return
        }
        directory = folder
        phase = .waiting
        message = "Finish signing in to \(agent.shortName) in Terminal, then return here."
        let deadline = ContinuousClock.now + timeout
        monitor = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                guard let self, self.generation == attempt else { return }
                if let data = try? String(contentsOf: result, encoding: .utf8), let code = Int(data.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    self.completedCode = code
                    self.phase = .checking
                    self.message = "Checking the \(agent.shortName) connection…"
                    let readiness = await verify()
                    guard !Task.isCancelled, self.generation == attempt else { return }
                    if readiness == .ready, self.canConfirm(self.latestStatus) { self.confirm() }
                    else if case .unavailable(let reason) = readiness {
                        self.fail("Couldn't verify sign-in. Check Again before retrying. \(reason)")
                    } else if code != 0 {
                        self.fail("Sign-in ended with exit code \(code). Retry Sign In to open Terminal again.")
                    } else {
                        self.fail("The CLI finished, but sign-in isn't confirmed. Check Again or retry sign-in.")
                    }
                    self.cleanFinishedCommand()
                    return
                }
                if ContinuousClock.now >= deadline {
                    self.fail("Sign-in is taking longer than expected. Finish in Terminal and choose Check Again, or retry sign-in.")
                    return
                }
                do { try await Task.sleep(for: pollInterval) } catch { return }
            }
        }
    }

    public func update(status: AgentStatus) {
        latestStatus = status
        if completedCode == nil, let directory, let text = try? String(contentsOf: directory.appendingPathComponent("result"), encoding: .utf8) {
            completedCode = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if status.readiness == .ready, phase != .idle, canConfirm(status) {
            confirm()
        } else if phase == .succeeded, status.readiness != .ready {
            phase = .idle; message = nil
        }
    }

    private func canConfirm(_ status: AgentStatus?) -> Bool {
        // Switching accounts starts with a working login. Seeing that same account
        // again must not claim the new Terminal handoff has completed.
        guard let previousStatus, previousStatus.readiness == .ready else { return true }
        let changedAccount = previousStatus.account.flatMap { previous in status?.account.map { $0 != previous } } ?? false
        return completedCode == 0 || changedAccount
    }

    private func confirm() {
        generation = UUID(); monitor?.cancel(); monitor = nil
        phase = .succeeded; message = "Sign-in confirmed."
        cleanFinishedCommand()
    }

    /// The user owns Terminal; stopping observation must not terminate their login process.
    public func stopWaiting() {
        generation = UUID(); monitor?.cancel(); monitor = nil
        phase = .idle; message = nil
        cleanFinishedCommand()
    }

    private func fail(_ reason: String) { phase = .failed; message = reason }
    private func cleanFinishedCommand() {
        guard let directory, FileManager.default.fileExists(atPath: directory.appendingPathComponent("result").path) else { return }
        try? FileManager.default.removeItem(at: directory)
        self.directory = nil
    }
}
