import Foundation

public enum PreviewRecovery {
    /// A failed page may start only its own project's configured local preview.
    public static func matches(_ page: URL?, configuration: PreviewConfiguration?, runningAddress: URL? = nil) -> Bool {
        guard let page, let configuration, !configuration.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let configured = URL(string: configuration.address) else { return false }
        return [configured, runningAddress].compactMap { $0 }.contains { sameOrigin(page, $0) }
    }

    private static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func local(_ url: URL) -> Bool {
            ["http", "https"].contains(url.scheme?.lowercased() ?? "") &&
                ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "") &&
                url.user == nil && url.password == nil
        }
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return local(a) && local(b) && a.scheme?.lowercased() == b.scheme?.lowercased() && port(a) == port(b)
    }

    /// A dev server can choose a new port. Preserve the failed page's route and query.
    public static func reloadURL(_ page: URL, server: URL) -> URL? {
        guard var target = URLComponents(url: page, resolvingAgainstBaseURL: false),
              let origin = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return nil }
        target.scheme = origin.scheme; target.host = origin.host; target.port = origin.port
        return target.url
    }
}
