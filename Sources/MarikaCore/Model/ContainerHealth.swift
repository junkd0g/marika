import Foundation

public struct ContainerHealthIssue: Identifiable, Sendable {
    public var id: String { resource.id + ":" + category.rawValue }
    public enum Category: String, CaseIterable, Sendable { case workload = "Workloads", job = "Failed jobs", restart = "Restarts" }
    public var resource: ContainerResource
    public var category: Category
    public var detail: String
}

public struct ContainerHealth: Sendable {
    public var issues: [ContainerHealthIssue] = []
    public var readyWorkloads = 0
    public var totalWorkloads = 0
    public var failedJobs = 0
    public var completedJobs = 0
    public var suspendedJobs = 0
    public var runningJobs = 0
    public var restarts = 0
    public var warnings = 0
    public var unhealthyWorkloads: Int { issues.filter { $0.category == .workload }.count }
    public init(_ inventory: ContainerInventory) {
        let resources = inventory.resources
        let byUID = Dictionary(resources.filter { !$0.uid.isEmpty }.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        warnings = inventory.events.filter(\.warning).count
        for resource in resources {
            switch resource.kind {
            case .deployment, .statefulSet, .daemonSet, .container:
                totalWorkloads += 1
                if resource.condition == .ready || resource.condition == .stopped { readyWorkloads += 1 }
                else { issues.append(ContainerHealthIssue(resource: resource, category: .workload, detail: resource.failureMessage.isEmpty ? resource.status : resource.failureMessage)) }
            case .job:
                switch resource.condition {
                case .complete: completedJobs += 1
                case .suspended: suspendedJobs += 1
                case .failed:
                    failedJobs += 1
                    issues.append(ContainerHealthIssue(resource: resource, category: .job, detail: resource.failureMessage.isEmpty ? resource.detail : resource.failureMessage))
                default: runningJobs += 1
                }
            case .pod:
                restarts += resource.restarts
                // Terminal Job pods are attempts, not separate failed applications.
                if resource.ownerKind != "Job" && resource.condition != .complete && resource.condition != .ready {
                    var owner = resource.ownerUID.flatMap { byUID[$0] }
                    if owner?.kind == .replicaSet { owner = owner?.ownerUID.flatMap { byUID[$0] } }
                    if owner == nil || owner?.condition == .ready {
                        issues.append(ContainerHealthIssue(resource: resource, category: .workload, detail: resource.detail))
                    }
                }
                if resource.restarts > 0 && resource.condition != .complete {
                    issues.append(ContainerHealthIssue(resource: resource, category: .restart, detail: "\(resource.restarts) container restarts"))
                }
            default: break
            }
        }
        let priority: [ContainerHealthIssue.Category: Int] = [.workload: 0, .job: 1, .restart: 2]
        issues.sort {
            if $0.category != $1.category { return priority[$0.category, default: 9] < priority[$1.category, default: 9] }
            if $0.category == .job {
                let left = $0.resource.finishedAt ?? $0.resource.startedAt ?? $0.resource.createdAt ?? .distantPast
                let right = $1.resource.finishedAt ?? $1.resource.startedAt ?? $1.resource.createdAt ?? .distantPast
                if left != right { return left > right }
            }
            return $0.resource.name < $1.resource.name
        }
    }
}

public struct ContainerHealthSnapshot: Identifiable, Sendable {
    public var id: String { target.id }
    public var target: ContainerTarget
    public var inventory: ContainerInventory?
    public var error: String?
    public var checkedAt: Date
    public var health: ContainerHealth? { inventory.map(ContainerHealth.init) }
    public init(target: ContainerTarget, inventory: ContainerInventory? = nil, error: String? = nil, checkedAt: Date = Date()) {
        self.target = target; self.inventory = inventory; self.error = error; self.checkedAt = checkedAt
    }
}
