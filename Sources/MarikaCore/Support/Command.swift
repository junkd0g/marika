import Darwin
import Foundation

/// The outcome of a short-lived command.
public struct CommandResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public var succeeded: Bool { status == 0 && !timedOut }
    public var output: String { String(decoding: stdout, as: UTF8.self) }
    public var errorOutput: String { String(decoding: stderr, as: UTF8.self) }
}

public enum Command {
    /// Runs a command in its own process group. Cancellation and timeouts stop its descendants too.
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 20,
        outputLimit: Int? = nil,
        inputFile: URL? = nil
    ) async throws -> CommandResult {
        guard timeout.isFinite, timeout >= 0 else { throw POSIXError(.EINVAL) }
        let runner = Runner(outputLimit: outputLimit)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await withCheckedThrowingContinuation { continuation in
                runner.start(executable, arguments, directory: workingDirectory,
                             environment: environment ?? ProcessInfo.processInfo.environment,
                             timeout: timeout, inputFile: inputFile, continuation: continuation)
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            runner.stop(timedOut: false)
        }
    }

    private final class Runner: @unchecked Sendable {
        private let outputLimit: Int?
        init(outputLimit: Int?) { self.outputLimit = outputLimit.map { max(0, $0) } }
        private let lock = NSLock()
        private let stdout = Pipe()
        private let stderr = Pipe()
        private let drained = DispatchGroup()
        private var pid: pid_t = 0
        private var finished = false
        private var cancelled = false
        private var timedOut = false
        private var output = Data()
        private var errorOutput = Data()

        func start(_ executable: URL, _ arguments: [String], directory: URL?, environment: [String: String],
                   timeout: TimeInterval, inputFile: URL?, continuation: CheckedContinuation<CommandResult, Error>) {
            do {
                // Keep cancellation and spawn atomic, including cancellation before a PID exists.
                try lock.withLock {
                    guard !cancelled else { throw CancellationError() }
                    guard !([executable.path] + arguments).contains(where: { $0.contains("\0") }),
                          !environment.contains(where: { $0.key.contains("=") || $0.key.contains("\0") || $0.value.contains("\0") })
                    else { throw POSIXError(.EINVAL) }
                    var actions: posix_spawn_file_actions_t?
                    var attributes: posix_spawnattr_t?
                    func check(_ code: Int32) throws {
                        if code != 0 { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EINVAL) }
                    }
                    try check(posix_spawn_file_actions_init(&actions))
                    defer { posix_spawn_file_actions_destroy(&actions) }
                    try check(posix_spawnattr_init(&attributes))
                    defer { posix_spawnattr_destroy(&attributes) }
                    try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
                    try check(posix_spawnattr_setpgroup(&attributes, 0))
                    if let directory { try check(posix_spawn_file_actions_addchdir_np(&actions, directory.path)) }
                    try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, inputFile?.path ?? "/dev/null", O_RDONLY, 0))
                    try check(posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO))
                    try check(posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO))
                    let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
                    let env = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
                    defer { argv.forEach { free($0) }; env.forEach { free($0) } }
                    var child: pid_t = 0
                    let code = argv.withUnsafeBufferPointer { argv in
                        env.withUnsafeBufferPointer { env in
                            posix_spawn(&child, executable.path, &actions, &attributes,
                                        UnsafeMutablePointer(mutating: argv.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
                        }
                    }
                    try check(code)
                    pid = child
                }
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForWriting.close()
                observe(stdout.fileHandleForReading, isError: false)
                observe(stderr.fileHandleForReading, isError: true)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.stop(timedOut: true) }
                let child = lock.withLock { pid }
                DispatchQueue.global().async { [self] in
                    // Observe exit without reaping first: keeping the PID reserved prevents
                    // cleanup from ever signaling a newly reused process group.
                    var info = siginfo_t()
                    var observed: Int32
                    repeat { observed = waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) } while observed == -1 && errno == EINTR
                    lock.withLock {
                        if observed == 0 { kill(-child, SIGKILL) }
                        finished = true
                    }
                    var status: Int32 = 0
                    var waited: pid_t
                    repeat { waited = waitpid(child, &status, 0) } while waited == -1 && errno == EINTR
                    _ = drained.wait(timeout: .now() + 0.5)
                    closeReaders()
                    let code = waited == -1 ? Int32(127) : (status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
                    continuation.resume(returning: lock.withLock {
                        CommandResult(status: code, stdout: output, stderr: errorOutput, timedOut: timedOut)
                    })
                }
            } catch {
                lock.withLock { finished = true }
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForWriting.close()
                closeReaders()
                continuation.resume(throwing: error)
            }
        }

        private func observe(_ handle: FileHandle, isError: Bool) {
            drained.enter()
            handle.readabilityHandler = { [self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    drained.leave()
                } else {
                    lock.withLock {
                        if isError { errorOutput.append(data) } else { output.append(data) }
                        if let outputLimit {
                            if isError { errorOutput = errorOutput.suffix(outputLimit) }
                            else { output = output.suffix(outputLimit) }
                        }
                    }
                }
            }
        }

        private func closeReaders() {
            for handle in [stdout.fileHandleForReading, stderr.fileHandleForReading] {
                handle.readabilityHandler = nil
                try? handle.close()
            }
        }

        func stop(timedOut: Bool) {
            let child: pid_t = lock.withLock {
                guard !finished else { return 0 }
                if timedOut { self.timedOut = true } else { cancelled = true }
                guard pid > 0 else { return 0 }
                kill(-pid, SIGTERM)
                return pid
            }
            guard child > 0 else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                self.lock.withLock {
                    // Never let an old watchdog signal a later command.
                    if !self.finished, self.pid == child { kill(-child, SIGKILL) }
                }
            }
        }
    }
}
