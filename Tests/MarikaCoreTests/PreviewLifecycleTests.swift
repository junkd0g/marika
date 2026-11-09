import Darwin
import Foundation
import Testing
@testable import MarikaCore

struct PreviewLifecycleTests {
    private func listener() throws -> (Int32, URL) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 1) == 0 else { close(fd); throw POSIXError(.EINVAL) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (fd, URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))")!)
    }

    @MainActor @Test func occupiedPortFailsBeforeLaunchingAndLeavesOtherServerAlone() throws {
        let (fd, url) = try listener(); defer { close(fd) }
        let preview = ProjectPreview()
        var opened = false; preview.onReady = { _ in opened = true }
        preview.start(PreviewConfiguration(command: "exit 0", address: url.absoluteString), at: FileManager.default.temporaryDirectory, environment: [:])
        #expect(preview.state == .failed && preview.portConflict == url.port)
        #expect(preview.error?.contains("already in use") == true && !opened)
        preview.stop()
        #expect(PreviewPort.isOccupied(url))
    }

    @MainActor @Test func exitsAndTimeoutsBecomeActionableFailures() async throws {
        let (fd, url) = try listener(); close(fd)
        let preview = ProjectPreview(startupTimeout: .milliseconds(300))
        preview.start(PreviewConfiguration(command: "exit 0", address: url.absoluteString), at: FileManager.default.temporaryDirectory, environment: [:])
        for _ in 0..<40 where preview.state == .starting { try await Task.sleep(for: .milliseconds(50)) }
        #expect(preview.state == .failed && preview.error?.contains("before the server was ready") == true)
        preview.start(PreviewConfiguration(command: "/bin/sleep 20", address: url.absoluteString), at: FileManager.default.temporaryDirectory, environment: [:])
        for _ in 0..<80 where preview.state == .starting { try await Task.sleep(for: .milliseconds(50)) }
        #expect(preview.state == .failed && preview.error?.contains("not responding") == true)
        preview.stop()
    }

    @MainActor @Test func invalidAddressesDoNotLaunch() {
        for address in ["https://example.com", "file:///tmp/page", "http://secret@localhost:12345"] {
            let preview = ProjectPreview()
            preview.start(PreviewConfiguration(command: "exit 0", address: address), at: FileManager.default.temporaryDirectory, environment: [:])
            #expect(preview.state == .failed && !preview.isActive)
        }
    }
}
