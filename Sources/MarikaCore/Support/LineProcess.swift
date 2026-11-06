import Foundation

extension String {
    /// Removes the colour codes CLIs add to their logs.
    var withoutTerminalCodes: String {
        replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }
}

/// A long-running child process that speaks newline-delimited JSON on stdio.
///
/// Lines are delivered in order on `output`. The stream ends with one `.exited` after the
/// process has terminated and its stdout has drained.
public final class LineProcess: @unchecked Sendable {
    public enum Output: Sendable {
        case line(Data)
        case exited(status: Int32, stderrTail: String)
    }

    public let output: AsyncStream<Output>

    private let continuation: AsyncStream<Output>.Continuation
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let writeQueue = DispatchQueue(label: "app.marika.process.stdin")

    private let lock = NSLock()
    private var buffer = Data()
    private var stderrTail = Data()
    private var stdoutClosed = false
    private var exitStatus: Int32?
    private var finished = false
    private var inputClosed = false

    private static let stderrLimit = 16 * 1024
    /// A background job started by the agent can inherit stdout and keep it open after the
    /// agent itself has exited, so never wait for EOF indefinitely.
    private static let drainGrace: TimeInterval = 1.5

    /// Writing to a pipe whose reader has gone raises SIGPIPE, which would kill the whole
    /// app. A write failure is reported through the normal exit path instead.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    public init(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL) {
        (output, continuation) = AsyncStream.makeStream(of: Output.self)
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    public func start() throws {
        _ = Self.ignoreSIGPIPE

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self?.markStdoutClosed()
            } else {
                self?.consume(chunk)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self?.keepStderr(chunk)
            }
        }
        process.terminationHandler = { [weak self] process in
            self?.markExited(process.terminationStatus)
        }
        try process.run()
    }

    public var isRunning: Bool { process.isRunning }

    /// Queues one line for the child's stdin. Failures surface through `.exited`.
    public func write(_ line: Data) {
        let payload = line + [0x0A]
        let handle = stdin.fileHandleForWriting
        writeQueue.async { [weak self] in
            guard let self, !self.isInputClosed else { return }
            try? handle.write(contentsOf: payload)
        }
    }

    /// Ends the child's input. Well-behaved agents treat this as a request to shut down.
    public func closeInput() {
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                guard !self.inputClosed else { return }
                self.inputClosed = true
                try? self.stdin.fileHandleForWriting.close()
            }
        }
    }

    public func terminate() {
        if process.isRunning { process.terminate() }
    }

    /// Ends the process even if it ignores SIGTERM.
    public func forceKill() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private var isInputClosed: Bool { lock.withLock { inputClosed } }

    // MARK: Framing

    private func consume(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let scanned = buffer.count
        buffer.append(chunk)
        var lineStart = buffer.startIndex
        var cursor = buffer.startIndex + scanned
        while let newline = buffer[cursor...].firstIndex(of: 0x0A) {
            if newline > lineStart {
                continuation.yield(.line(Data(buffer[lineStart..<newline])))
            }
            lineStart = newline + 1
            cursor = lineStart
        }
        if lineStart > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<lineStart)
        }
    }

    private func keepStderr(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        stderrTail.append(chunk)
        if stderrTail.count > Self.stderrLimit {
            stderrTail.removeFirst(stderrTail.count - Self.stderrLimit)
        }
    }

    // MARK: Lifecycle

    private func markStdoutClosed() {
        lock.lock()
        stdoutClosed = true
        lock.unlock()
        finishIfDone()
    }

    private func markExited(_ status: Int32) {
        lock.lock()
        exitStatus = status
        lock.unlock()
        finishIfDone()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.drainGrace) { [weak self] in
            self?.finishIfDone(force: true)
        }
    }

    private func finishIfDone(force: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, let status = exitStatus, stdoutClosed || force else { return }
        finished = true
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        if !buffer.isEmpty {
            continuation.yield(.line(buffer))
            buffer = Data()
        }
        let tail = String(decoding: stderrTail, as: UTF8.self).withoutTerminalCodes
        continuation.yield(.exited(status: status, stderrTail: tail))
        continuation.finish()
    }
}
