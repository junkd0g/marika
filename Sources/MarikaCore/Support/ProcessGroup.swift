import Darwin
import Foundation

/// A child process and its descendants, stopped together without touching other jobs.
public final class ProcessGroup: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var finished = false
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let output: @Sendable (Data) -> Void
    private let completion: @Sendable (Int32) -> Void

    public init(output: @escaping @Sendable (Data) -> Void, completion: @escaping @Sendable (Int32) -> Void) {
        self.output = output; self.completion = completion
    }
    public var isRunning: Bool { lock.withLock { pid > 0 && !finished } }

    public func start(command: String, directory: URL, environment: [String: String]) throws {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, stdout.fileHandleForReading.fileDescriptor)
        posix_spawn_file_actions_addclose(&actions, stderr.fileHandleForReading.fileDescriptor)
        let commandArguments: [String] = ["/bin/zsh", "-l", "-c", command]
        let arguments: [UnsafeMutablePointer<CChar>?] = commandArguments.map { value in
            value.withCString { Darwin.strdup($0) }
        } + [nil]
        let variables: [UnsafeMutablePointer<CChar>?] = environment.sorted { $0.key < $1.key }.map { key, value in
            (key + "=" + value).withCString { Darwin.strdup($0) }
        } + [nil]
        defer { arguments.forEach { free($0) }; variables.forEach { free($0) } }
        var child: pid_t = 0
        let result = arguments.withUnsafeBufferPointer { argv in
            variables.withUnsafeBufferPointer { env in
                posix_spawn(&child, "/bin/zsh", &actions, &attributes,
                            UnsafeMutablePointer(mutating: argv.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL) }
        lock.withLock { pid = child }
        try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
        for handle in [stdout.fileHandleForReading, stderr.fileHandleForReading] {
            handle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                else { self?.output(data) }
            }
        }
        let processID = child
        DispatchQueue.global().async { [self] in
            var status: Int32 = 0
            while waitpid(processID, &status, 0) == -1 && errno == EINTR {}
            lock.withLock { finished = true }
            // A shell may exit while a child still owns its pipes.
            kill(-processID, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { kill(-processID, SIGKILL) }
            let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            completion(code)
        }
    }

    public func stop() {
        let processID = lock.withLock { finished ? 0 : pid }
        guard processID > 0 else { return }
        kill(-processID, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            lock.withLock { if pid == processID { kill(-processID, SIGKILL) } }
        }
    }
}
