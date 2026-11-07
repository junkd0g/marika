import Foundation

public struct ReleaseVersion: Comparable, Equatable, Sendable {
    public let display: String
    private let numbers: [Int]
    private let prerelease: [String]

    public init?(_ value: String) {
        guard value.count <= 120 else { return nil }
        let value = value.hasPrefix("v") || value.hasPrefix("V") ? String(value.dropFirst()) : value
        guard !value.isEmpty else { return nil }
        let build = value.split(separator: "+", omittingEmptySubsequences: false)
        guard build.count <= 2 else { return nil }
        func validIdentifiers(_ value: Substring) -> Bool {
            value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
            }
        }
        if build.count == 2, !validIdentifiers(build[1]) { return nil }
        let parts = build[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let rawNumbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(rawNumbers.count), rawNumbers.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        var numbers = rawNumbers.compactMap { Int($0) }
        guard numbers.count == rawNumbers.count else { return nil }
        while numbers.count < 3 { numbers.append(0) }
        if parts.count == 2, !validIdentifiers(parts[1]) { return nil }
        self.numbers = numbers
        prerelease = parts.count == 2 ? parts[1].split(separator: ".").map(String.init) : []
        guard prerelease.allSatisfy({ !($0.count > 1 && $0.first == "0" && $0.utf8.allSatisfy { (48...57).contains($0) }) }) else { return nil }
        display = value
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.numbers == rhs.numbers && lhs.prerelease == rhs.prerelease }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftNumeric = left.utf8.allSatisfy { (48...57).contains($0) }
            let rightNumeric = right.utf8.allSatisfy { (48...57).contains($0) }
            if leftNumeric && rightNumeric { return left.count == right.count ? left < right : left.count < right.count }
            if leftNumeric != rightNumeric { return leftNumeric }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

public struct PublishedRelease: Equatable, Sendable {
    public let version: ReleaseVersion
    public let title: String
    public let notes: String
    public let url: URL
    public let publishedAt: Date?

    public init(version: ReleaseVersion, title: String, notes: String, url: URL, publishedAt: Date? = nil) {
        self.version = version; self.title = title; self.notes = notes; self.url = url; self.publishedAt = publishedAt
    }
}

public struct SignedUpdateConfiguration: Equatable, Sendable {
    public let feedURL: URL
    public let publicKey: String

    public init?(feedURL: String?, publicKey: String?) {
        guard let feedURL, let url = URL(string: feedURL), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, let publicKey,
              Data(base64Encoded: publicKey)?.count == 32 else { return nil }
        self.feedURL = url; self.publicKey = publicKey
    }
}

public struct ReleaseCheckError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

public actor ReleaseChecker {
    public static let repositoryURL = URL(string: "https://github.com/junkd0g/marika")!
    public static let endpoint = URL(string: "https://api.github.com/repos/junkd0g/marika/releases/latest")!
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let fetch: Fetch

    public init(fetch: Fetch? = nil) {
        self.fetch = fetch ?? { request in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw ReleaseCheckError(message: "The update server returned an invalid response.")
            }
            return (data, response)
        }
    }

    public func latest() async throws -> PublishedRelease? {
        try Task.checkCancellation()
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Marika/" + marikaCoreVersion, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await fetch(request)
        try Task.checkCancellation()
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else {
            throw ReleaseCheckError(message: response.statusCode == 403 || response.statusCode == 429
                ? "GitHub is limiting update checks. Please try again later."
                : "Couldn't check for updates (HTTP \(response.statusCode)). Try again.")
        }
        guard data.count <= 2_000_000 else { throw ReleaseCheckError(message: "The release response was too large.") }
        struct Payload: Decodable {
            var tag_name: String
            var name: String?
            var body: String?
            var html_url: String
            var published_at: String?
            var draft: Bool
            var prerelease: Bool
        }
        let release: Payload
        do { release = try JSONDecoder().decode(Payload.self, from: data) }
        catch { throw ReleaseCheckError(message: "The update server returned unreadable release information.") }
        guard !release.draft, !release.prerelease else { return nil }
        guard let version = ReleaseVersion(release.tag_name), let url = URL(string: release.html_url),
              url.scheme == "https", url.host?.lowercased() == "github.com", url.user == nil, url.password == nil,
              url.path.hasPrefix("/junkd0g/marika/releases/tag/") else {
            throw ReleaseCheckError(message: "The release information contained an invalid version or download page.")
        }
        return PublishedRelease(version: version, title: String((release.name ?? release.tag_name).prefix(200)),
            notes: String((release.body ?? "No release notes were provided.").prefix(100_000)), url: url,
            publishedAt: release.published_at.flatMap { ISO8601DateFormatter().date(from: $0) })
    }
}
