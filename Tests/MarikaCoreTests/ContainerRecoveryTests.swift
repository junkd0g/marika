import Foundation
import Testing
@testable import MarikaCore

private actor RecoveryEngine {
    var source: JSONValue
    var replicas: JSONValue
    var commands: [ContainerCommand] = []
    var created: [Data] = []
    init(source: JSONValue, replicas: JSONValue = ["items": []]) { self.source = source; self.replicas = replicas }
    func replace(_ source: JSONValue) { self.source = source }
    func run(_ command: ContainerCommand) throws -> ContainerCommandResult {
        commands.append(command)
        let args = command.arguments
        if args.contains("jsonpath={.metadata.uid}") { return ContainerCommandResult(output: source["metadata"]?["uid"]?.string ?? "") }
        if args.contains("get") {
            let response = args.contains("replicasets") ? replicas : source
            return ContainerCommandResult(output: String(decoding: try response.serialized(), as: UTF8.self))
        }
        if args.contains("create"), let index = args.firstIndex(of: "-f") { created.append(try Data(contentsOf: URL(fileURLWithPath: args[index + 1]))) }
        return ContainerCommandResult(output: "done")
    }
}

struct ContainerRecoveryTests {
    private let target = ContainerTarget(name: "explicit-cluster")
    private func object(_ kind: String, name: String = "worker", spec: JSONValue, status: JSONValue = [:], uid: String = "one") -> JSONValue {
        ["kind": .string(kind), "metadata": ["name": .string(name), "namespace": "app", "uid": .string(uid)], "spec": spec, "status": status]
    }
    private func decode(_ items: [JSONValue]) throws -> [ContainerResource] {
        try ContainerDecoding.kubernetes(JSONValue.object(["items": .array(items)]).serialized())
    }
    private var jobSpec: JSONValue {
        ["selector": ["matchLabels": ["batch.kubernetes.io/controller-uid": "old"]], "backoffLimit": 2,
         "template": ["metadata": ["labels": ["batch.kubernetes.io/controller-uid": "old", "job-name": "old", "app": "worker"]],
                      "spec": ["restartPolicy": "Never", "containers": [["name": "worker", "image": "worker:one", "env": [["name": "TOKEN", "value": "private-value"]]]]]]]
    }
    @Test func jobsDistinguishTerminalFailureRetriesCompletionAndSuspension() throws {
        let items = try decode([
            object("Job", name: "recovered", spec: jobSpec, status: ["succeeded": 1, "failed": 2, "conditions": [["type": "Complete", "status": "True"]]]),
            object("Job", name: "retrying", spec: jobSpec, status: ["active": 1, "failed": 1]),
            object("Job", name: "failed", spec: jobSpec, status: ["failed": 3, "conditions": [["type": "Failed", "status": "True", "reason": "BackoffLimitExceeded", "message": "Retry budget exhausted"]]]),
            object("Job", name: "paused", spec: ["suspend": true, "template": jobSpec["template"]!], status: ["failed": 2])])
        #expect(items.map(\.condition) == [.complete, .pending, .failed, .suspended])
        #expect(items[1].status == "Retrying" && items[1].activeJobs == 1)
        #expect(items[2].failureReason == "BackoffLimitExceeded" && items[2].failureMessage == "Retry budget exhausted")
    }
    @Test func cronjobsIncludeScheduleTimeZoneHistoryAndOwnership() throws {
        let cron = object("CronJob", name: "nightly", spec: ["schedule": "0 2 * * *", "timeZone": "Europe/London", "suspend": true, "jobTemplate": ["spec": jobSpec]],
            status: ["active": [["uid": "job"]], "lastScheduleTime": "2026-11-11T02:00:00Z", "lastSuccessfulTime": "2026-11-10T02:00:05Z"])
        let value = try #require(decode([cron]).first)
        #expect(value.kind == .cronJob && value.condition == .suspended && value.activeJobs == 1)
        #expect(value.schedule == "0 2 * * *" && value.timeZone == "Europe/London" && value.lastScheduledAt != nil && value.lastSuccessfulAt != nil)
        #expect(value.image == "worker:one")
    }
    @Test func healthDoesNotCountTerminalJobAttemptsAsBrokenApplications() throws {
        let complete = object("Job", name: "finished", spec: jobSpec, status: ["succeeded": 1, "failed": 2])
        let failed = object("Job", name: "broken", spec: jobSpec, status: ["conditions": [["type": "Failed", "status": "True"]]])
        let pod: JSONValue = ["kind": "Pod", "metadata": ["name": "attempt", "uid": "pod", "namespace": "app", "ownerReferences": [["kind": "Job", "uid": "one", "name": "finished", "controller": true]]], "spec": ["containers": [["name": "worker", "image": "worker:one"]]], "status": ["phase": "Failed"]]
        var inventory = ContainerInventory(); inventory.resources = try decode([complete, failed, pod])
        let health = ContainerHealth(inventory)
        #expect(health.completedJobs == 1 && health.failedJobs == 1 && health.unhealthyWorkloads == 0)
    }
    @Test func previousAndInitContainerLogsRemainScoped() throws {
        let data = object("Pod", spec: ["containers": [["name": "api", "image": "api:one"]], "initContainers": [["name": "setup", "image": "setup:one"]]],
            status: ["phase": "Running", "containerStatuses": [["name": "api", "ready": true, "restartCount": 2]], "initContainerStatuses": [["name": "setup", "restartCount": 0, "state": ["terminated": ["exitCode": 0, "reason": "Completed"]]]]])
        let pod = try #require(decode([data]).first)
        #expect(pod.containers.count == 2 && pod.containers.last?.isInit == true)
        let plan = try ContainerPlans.podLogs(pod, target: target, container: "api", previous: true)
        #expect(plan.arguments.contains("explicit-cluster") && plan.arguments.contains("app") && plan.arguments.contains("--previous=true") && plan.arguments.contains("api"))
        #expect(throws: ContainerHubError.self) { try ContainerPlans.podLogs(pod, target: target, container: "other", previous: false) }
        #expect(throws: ContainerHubError.self) { try ContainerPlans.podLogs(pod, target: target, container: nil, previous: true) }
    }
    @Test func retryCreatesAnIndependentJobWithoutDeletingOrReusingSelectors() async throws {
        let source = object("Job", spec: jobSpec), resource = try #require(decode([source]).first)
        let engine = RecoveryEngine(source: source)
        let cli = ContainerCLI(root: URL(fileURLWithPath: "/tmp"), environment: [:], runner: { try await engine.run($0) })
        let review = try await cli.prepareRetry(resource, target: target)
        #expect(await engine.created.isEmpty)
        #expect(!review.after.contains("private-value"))
        let job = try JSONValue(parsing: #require(review.jobData))
        #expect(job["spec"]?["selector"] == nil && job["spec"]?["suspend"]?.bool == false)
        #expect(job["spec"]?["template"]?["metadata"]?["labels"]?["job-name"] == nil)
        #expect(job["spec"]?["template"]?["metadata"]?["labels"]?["app"]?.string == "worker")
        #expect(job["spec"]?["template"]?["spec"]?["containers"]?[0]?["env"]?[0]?["value"]?.string == "private-value")
        _ = try await cli.recover(review)
        #expect(await engine.created == [review.jobData!])
        let commands = await engine.commands
        #expect(commands.allSatisfy { !$0.arguments.contains("delete") && !$0.arguments.contains("apply") })
        #expect(commands.last?.arguments.contains("explicit-cluster") == true)
        let path = commands.last!.arguments.last!; #expect(!FileManager.default.fileExists(atPath: path))
    }
    @Test func cronjobManualRunPreservesItsSuspendedSchedule() async throws {
        let source = object("CronJob", spec: ["schedule": "0 2 * * *", "suspend": true, "jobTemplate": ["spec": jobSpec]])
        let resource = try #require(decode([source]).first), engine = RecoveryEngine(source: source)
        let cli = ContainerCLI(root: URL(fileURLWithPath: "/tmp"), environment: [:], runner: { try await engine.run($0) })
        let review = try await cli.prepareRetry(resource, target: target)
        #expect(review.sourceSpec["suspend"]?.bool == true)
        #expect(try JSONValue(parsing: review.jobData!)["spec"]?["suspend"]?.bool == false)
    }
    @Test func changedOrReplacedWorkloadRejectsRecovery() async throws {
        let source = object("Job", spec: jobSpec), resource = try #require(decode([source]).first), engine = RecoveryEngine(source: source)
        let cli = ContainerCLI(root: URL(fileURLWithPath: "/tmp"), environment: [:], runner: { try await engine.run($0) })
        let review = try await cli.prepareRetry(resource, target: target)
        await engine.replace(object("Job", spec: ["template": jobSpec["template"]!, "backoffLimit": 9]))
        await #expect(throws: ContainerHubError.self) { try await cli.recover(review) }
        await engine.replace(object("Job", spec: jobSpec, uid: "replacement"))
        await #expect(throws: ContainerHubError.self) { try await cli.recover(review) }
        #expect(await engine.created.isEmpty)
    }
    @Test func rollbackRequiresOwnedRetainedRevisionAndUsesExplicitNumber() async throws {
        let source: JSONValue = ["kind": "Deployment", "metadata": ["name": "api", "namespace": "app", "uid": "deploy", "annotations": ["deployment.kubernetes.io/revision": "3"]], "spec": ["replicas": 2, "template": ["spec": ["containers": [["name": "api", "image": "api:three"]]]]]]
        func rs(_ revision: String, owner: String) -> JSONValue {
            ["metadata": ["name": .string("api-" + revision), "uid": .string("rs-" + revision), "annotations": ["deployment.kubernetes.io/revision": .string(revision)], "ownerReferences": [["uid": .string(owner), "controller": true]]], "spec": ["template": ["spec": ["containers": [["name": "api", "image": .string("api:" + revision)]]]]]]
        }
        let resource = try #require(decode([source]).first), engine = RecoveryEngine(source: source, replicas: ["items": [rs("2", owner: "deploy"), rs("1", owner: "other")]])
        let cli = ContainerCLI(root: URL(fileURLWithPath: "/tmp"), environment: [:], runner: { try await engine.run($0) })
        let revisions = try await cli.revisions(resource, target: target)
        #expect(revisions.map(\.revision) == [2])
        let review = try await cli.prepareRollback(resource, target: target, revision: revisions[0])
        _ = try await cli.recover(review)
        #expect(await engine.commands.last?.arguments.suffix(4) == ["rollout", "undo", "deployment/api", "--to-revision=2"])
    }
}
