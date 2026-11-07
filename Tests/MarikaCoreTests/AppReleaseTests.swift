import Foundation
import Testing
@testable import MarikaCore

private func releaseChecker(_ code: Int = 200, body: String) -> ReleaseChecker {
    let data = Data(body.utf8)
    return ReleaseChecker { request in
        #expect(request.url == ReleaseChecker.endpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        return (data, HTTPURLResponse(url: ReleaseChecker.endpoint, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}

private let releaseBody = ##"{"tag_name":"v0.2.0","name":"Marika 0.2","body":"# New release\nSearch conversations.","html_url":"https://github.com/junkd0g/marika/releases/tag/v0.2.0","published_at":"2026-11-07T12:00:00Z","draft":false,"prerelease":false}"##

struct AppReleaseTests {
    @Test func comparesReleaseNumbersNumericallyAndHandlesPrereleasesAndBuildMetadata() throws {
        let ordered = ["0.9.0", "0.10.0", "1.0.0-alpha", "1.0.0-alpha.2", "1.0.0-alpha.10", "1.0.0-beta", "1.0.0", "1.1.0"]
            .map { ReleaseVersion($0)! }
        #expect(ordered.sorted() == ordered)
        #expect(ReleaseVersion("v1.2.0+test") == ReleaseVersion("1.2"))
        #expect(ReleaseVersion("1.0.0")! > ReleaseVersion("1.0.0-rc.1")!)
        for value in ["", "v", "-1.0", "1..0", "1.0.0.", "1.0.0-", "1.0.0-beta..1", "1.0.0-01", "1.0+", "1.0+foo+bar", "release-1.0", "1.0.0/evil", String(repeating: "9", count: 200)] {
            #expect(ReleaseVersion(value) == nil)
        }
    }

    @Test func parsesPublishedReleaseNotesAndDateWithoutDownloadingOrInstallingAnything() async throws {
        let release = try #require(try await releaseChecker(body: releaseBody).latest())
        #expect(release.version == ReleaseVersion("0.2.0"))
        #expect(release.title == "Marika 0.2" && release.notes.contains("Search conversations."))
        #expect(release.publishedAt != nil)
        #expect(release.url.absoluteString.hasPrefix("https://github.com/junkd0g/marika/releases/tag/"))
    }

    @Test func noPublishedReleaseIsDifferentFromAnUpToDateRelease() async throws {
        #expect(try await releaseChecker(404, body: #"{"message":"Not Found"}"#).latest() == nil)
        #expect(try await releaseChecker(body: releaseBody).latest() != nil)
    }

    @Test func draftsAndPrereleasesAreNotOfferedAsStableUpdates() async throws {
        let draft = releaseBody.replacingOccurrences(of: #""draft":false"#, with: #""draft":true"#)
        let beta = releaseBody.replacingOccurrences(of: #""prerelease":false"#, with: #""prerelease":true"#)
        #expect(try await releaseChecker(body: draft).latest() == nil)
        #expect(try await releaseChecker(body: beta).latest() == nil)
    }

    @Test func failuresAndMalformedResponsesDoNotPretendTheAppIsUpToDate() async throws {
        for (code, body) in [(429, "limited"), (503, "unavailable"), (200, "broken"), (200, "{}"),
                             (200, releaseBody.replacingOccurrences(of: "https://github.com/", with: "https://evil.invalid/")),
                             (200, releaseBody.replacingOccurrences(of: "v0.2.0", with: "not-a-version"))] {
            await #expect(throws: ReleaseCheckError.self) { try await releaseChecker(code, body: body).latest() }
        }
    }

    @Test func installationRequiresAnHTTPSFeedAndAValidEd25519PublicKey() {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        #expect(SignedUpdateConfiguration(feedURL: "https://example.com/appcast.xml", publicKey: key) != nil)
        for feed in [nil, "", "http://example.com/appcast.xml", "file:///tmp/appcast.xml", "https://user:password@example.com/appcast.xml"] {
            #expect(SignedUpdateConfiguration(feedURL: feed, publicKey: key) == nil)
        }
        for invalid in [nil, "", "placeholder", Data(repeating: 7, count: 31).base64EncodedString()] {
            #expect(SignedUpdateConfiguration(feedURL: "https://example.com/appcast.xml", publicKey: invalid) == nil)
        }
    }

    @Test func cancelledChecksRemainCancelled() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await releaseChecker(body: releaseBody).latest()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
