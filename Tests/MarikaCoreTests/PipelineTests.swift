import Foundation
import Testing
@testable import MarikaCore

struct PipelineTests {
    @Test func workflowDiscoveryIncludesEventsAndBlocksDependentGitHubJobs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workflows = root.appendingPathComponent(".github/workflows")
        try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
        try """
        on: [push, workflow_dispatch]
        jobs:
          test:
            runs-on: ubuntu-latest
            steps: [{run: "echo ok"}]
          deploy:
            runs-on: ubuntu-latest
            environment: production
            needs: test
          after:
            runs-on: ubuntu-latest
            needs: deploy
        """.write(to: workflows.appendingPathComponent("ci.yml"), atomically: true, encoding: .utf8)
        let jobs = try await PipelineDiscovery.jobs(at: root)
        #expect(jobs.count == 6)
        #expect(jobs.filter { $0.reason == nil }.map(\.job) == ["test", "test"])
        #expect(Set(jobs.map(\.event)) == ["push", "workflow_dispatch"])
    }
}
