import CryptoKit
import Foundation

public struct QAPlaywrightResult: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var browserProject: String
    public var browser: String?
    public var outcome: String
    public var status: QAStatus
    public var attempts: Int
    public var error: String
    public var traceHint: String?
    public var traceID: UUID?
    public var ticketID: UUID?
}

public struct QAPlaywrightImport: Sendable {
    public static let maximumReportSize = 20_000_000
    public static let annotation = "marika-case"
    public let digest: String
    public let startedAt: Date?
    public let ignored: Int
    public let results: [QACaseResult]

    private struct Report: Decodable {
        var suites: [Suite]
        var config: Config?
        var stats: Stats?
        struct Stats: Decodable { var startTime: String? }
        struct Config: Decodable { var projects: [Project]? }
        struct Project: Decodable { var id: String; var use: Browser? }
        struct Browser: Decodable { var browserName: String? }
    }
    private struct Suite: Decodable {
        var specs: [Spec]?
        var suites: [Suite]?
    }
    private struct Spec: Decodable { var tests: [Test] }
    private struct Test: Decodable {
        var projectId: String
        var projectName: String
        var status: String
        var expectedStatus: String
        var annotations: [Annotation]?
        var results: [Attempt]
    }
    private struct Annotation: Decodable { var type: String; var description: String? }
    private struct Attempt: Decodable {
        var status: String
        var errors: [Failure]?
        var error: Failure?
        var attachments: [Attachment]?
    }
    private struct Failure: Decodable { var message: String? }
    private struct Attachment: Decodable { var name: String; var path: String? }

    public init(data: Data, cases: [QACase]) throws {
        guard data.count <= Self.maximumReportSize else { throw QAError("Choose a Playwright JSON report under 20 MB.") }
        let report: Report
        do { report = try JSONDecoder().decode(Report.self, from: data) }
        catch { throw QAError("This file is not a supported Playwright JSON report. Export using the JSON reporter.") }
        var grouped: [UUID: [QAPlaywrightResult]] = [:]
        let approved = Dictionary(cases.filter { $0.approved && !$0.archived }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let browsers = Dictionary((report.config?.projects ?? []).compactMap { project in
            project.use?.browserName.map { (project.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        var pending = report.suites
        var ignored = 0
        var matched = 0
        while let suite = pending.popLast() {
            pending.append(contentsOf: suite.suites ?? [])
            for test in (suite.specs ?? []).flatMap(\.tests) {
                let tags = (test.annotations ?? []).filter { $0.type == Self.annotation }
                let identity = tags.first?.description?.split(separator: ":") ?? []
                guard tags.count == 1, identity.count == 2, let id = UUID(uuidString: String(identity[0])),
                      let testCase = approved[id], Int(identity[1]) == testCase.revision else {
                    ignored += 1; continue
                }
                matched += 1
                guard matched <= 2_000 else { throw QAError("Import a smaller report with at most 2,000 matching browser results.") }
                let status: QAStatus
                switch test.status {
                case "unexpected": status = test.results.isEmpty ? .blocked : .failed
                case "expected" where test.expectedStatus == "passed" && test.results.last?.status == "passed": status = .passed
                default: status = .blocked
                }
                let failure = test.results.last { $0.status != "passed" && $0.status != "skipped" }
                let trace = (failure?.attachments ?? test.results.last?.attachments ?? []).first { $0.name == "trace" }
                let error = failure?.errors?.compactMap(\.message).first ?? failure?.error?.message ?? ""
                let result = QAPlaywrightResult(browserProject: String((test.projectName.isEmpty ? test.projectId : test.projectName).prefix(200)),
                    browser: browsers[test.projectId], outcome: String(test.status.prefix(40)), status: status,
                    attempts: test.results.count, error: String(error.prefix(6000)),
                    traceHint: trace?.path.map { String(URL(fileURLWithPath: $0).lastPathComponent.prefix(200)) })
                grouped[id, default: []].append(result)
            }
        }
        guard !grouped.isEmpty else {
            throw QAError("No results match a current approved case revision. Export the case again and run that Playwright test in CI.")
        }
        self.results = cases.compactMap { test in
            guard let observations = grouped[test.id] else { return nil }
            var result = QACaseResult(test)
            result.playwright = observations
            return result
        }
        self.ignored = ignored
        self.digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        self.startedAt = report.stats?.startTime.flatMap { formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
    }
}
