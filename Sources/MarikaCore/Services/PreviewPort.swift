import Darwin
import Foundation

/// Checks only local listening sockets. Never stops another project's process.
public enum PreviewPort {
    public static func isOccupied(_ url: URL) -> Bool {
        guard let host = url.host, ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) else { return false }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: ""), String(port), &hints, &result) == 0 else { return false }
        defer { freeaddrinfo(result) }
        var entry = result
        while let current = entry {
            let info = current.pointee
            let descriptor = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            if descriptor >= 0 {
                let status = bind(descriptor, info.ai_addr, info.ai_addrlen)
                let conflict = status != 0 && errno == EADDRINUSE
                close(descriptor)
                if conflict { return true }
            }
            entry = info.ai_next
        }
        return false
    }
}
