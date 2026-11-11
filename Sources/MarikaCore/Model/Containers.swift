import Foundation

public enum ContainerProvider: String, Codable, CaseIterable, Sendable { case docker = "Docker", kubernetes = "Kubernetes" }
public struct ContainerHubSettings: Codable, Hashable, Sendable {
    public var provider: ContainerProvider = .docker
    public var dockerContext = ""
    public var kubeContext = ""
    public var namespace = "default"
    public var composeFile = ""
    public var clusters: [LocalCluster] = []
    public var logConnection: ContainerLogConnection?
    public init() {}
}
public struct LocalCluster: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var dockerContext: String
    public init(name: String, dockerContext: String, id: UUID = UUID()) { self.id = id; self.name = name; self.dockerContext = dockerContext }
    public func configuration(in directory: URL) -> URL { directory.appendingPathComponent(id.uuidString).appendingPathComponent("config") }
}
public struct ContainerTarget: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var endpoint: String
    public var isCurrent: Bool
    public var kubeconfig: String?
    public init(id: String? = nil, name: String, endpoint: String = "", isCurrent: Bool = false, kubeconfig: String? = nil) {
        self.id = id ?? name; self.name = name; self.endpoint = endpoint; self.isCurrent = isCurrent; self.kubeconfig = kubeconfig
    }
    public var isLocalDocker: Bool { endpoint.hasPrefix("unix://") || endpoint.hasPrefix("npipe://") }
}
public enum ContainerResourceKind: String, CaseIterable, Sendable {
    case container = "Container", image = "Image", deployment = "Deployment", statefulSet = "StatefulSet"
    case daemonSet = "DaemonSet", job = "Job", cronJob = "CronJob", replicaSet = "ReplicaSet", pod = "Pod", service = "Service"
    public var symbol: String { switch self {
    case .container, .pod: "shippingbox"
    case .image: "square.stack.3d.up"
    case .deployment, .statefulSet, .daemonSet, .replicaSet: "square.3.layers.3d"
    case .job: "gearshape.2"
    case .cronJob: "clock.arrow.circlepath"
    case .service: "network"
    } }
    public var scalable: Bool { self == .deployment || self == .statefulSet }
    public var restartable: Bool { scalable || self == .daemonSet || self == .container }
    public var hasLogs: Bool { self == .container || self == .pod }
    public var kubectlName: String { rawValue.lowercased() }
}
public enum ContainerCondition: String, Sendable { case ready, pending, stopped, failed, complete, configured, suspended }
public struct ContainerLogSource: Hashable, Sendable {
    public var name: String
    public var isInit: Bool
    public var restarts: Int
    public var exitCode: Int?
    public var reason: String
    public init(name: String, isInit: Bool = false, restarts: Int = 0, exitCode: Int? = nil, reason: String = "") {
        self.name = name; self.isInit = isInit; self.restarts = restarts; self.exitCode = exitCode; self.reason = reason
    }
}
public struct ContainerResource: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: ContainerResourceKind
    public var namespace = ""
    public var uid = ""
    public var ownerUID: String?
    public var ownerName: String?
    public var ownerKind: String?
    public var image = ""
    public var condition: ContainerCondition = .pending
    public var status = ""
    public var detail = ""
    public var ports = ""
    public var localPort: Int?
    public var targetPort: Int?
    public var replicas: Int?
    public var ready = 0
    public var restarts = 0
    public var node = ""
    public var stack = ""
    public var networks: [String] = []
    public var labels: [String: String] = [:]
    public var selector: [String: String] = [:]
    public var containers: [ContainerLogSource] = []
    public var failureReason = ""
    public var failureMessage = ""
    public var schedule = ""
    public var timeZone = ""
    public var activeJobs = 0
    public var failedAttempts = 0
    public var isSuspended = false
    public var createdAt: Date?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var lastScheduledAt: Date?
    public var lastSuccessfulAt: Date?
    public var revision: Int?
    public init(id: String, name: String, kind: ContainerResourceKind) { self.id = id; self.name = name; self.kind = kind }
}
public struct ContainerEvent: Identifiable, Sendable {
    public var id: String
    public var resourceUID: String
    public var reason: String
    public var message: String
    public var warning: Bool
    public var timestamp: Date? = nil
}
public struct ContainerInventory: Sendable {
    public var resources: [ContainerResource] = []
    public var events: [ContainerEvent] = []
    public var warning: String?
    public var date = Date()
    public init() {}
}
public struct ContainerTopology: Sendable {
    public struct Node: Identifiable, Sendable {
        public var id: String
        public var title: String
        public var subtitle: String
        public var column: Int
        public var resourceID: String?
        public var condition: ContainerCondition
        public var symbol: String
    }
    public struct Edge: Sendable { public var from: String; public var to: String; public var isRouting = false }
    public var nodes: [Node] = []
    public var edges: [Edge] = []
    public var truncated = false
    public init(resources: [ContainerResource], provider: ContainerProvider) {
        let visible = resources.filter { $0.kind != .replicaSet }.prefix(90)
        truncated = resources.filter { $0.kind != .replicaSet }.count > 90
        let byUID = Dictionary(resources.filter { !$0.uid.isEmpty }.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        func add(_ resource: ContainerResource, column: Int) {
            let status = resource.kind == .pod ? resource.status + " · " + resource.detail : resource.status
            let subtitle = resource.namespace.isEmpty ? status : resource.namespace + " · " + status
            nodes.append(Node(id: resource.id, title: resource.name, subtitle: subtitle, column: column, resourceID: resource.id,
                              condition: resource.condition, symbol: resource.kind.symbol))
        }
        if provider == .docker {
            let containers = visible.filter { $0.kind == .container }
            for stack in Set(containers.map { $0.stack.isEmpty ? "Standalone" : $0.stack }).sorted() {
                nodes.append(Node(id: "stack:" + stack, title: stack, subtitle: stack == "Standalone" ? "Independent containers" : "Compose stack", column: 0,
                                  resourceID: nil, condition: .configured, symbol: "square.stack.3d.up"))
            }
            for container in containers {
                add(container, column: 1)
                edges.append(Edge(from: "stack:" + (container.stack.isEmpty ? "Standalone" : container.stack), to: container.id))
            }
            let images = visible.filter { $0.kind == .image }
            for image in images { add(image, column: 2) }
            for container in containers {
                if let image = images.first(where: { $0.name == container.image || $0.uid == container.image }) { edges.append(Edge(from: container.id, to: image.id)) }
            }
        } else {
            for resource in visible { add(resource, column: resource.kind == .service ? 0 : resource.kind == .pod ? 2 : 1) }
            let pods = visible.filter { $0.kind == .pod }
            for pod in pods {
                var owner = pod.ownerUID.flatMap { byUID[$0] }
                if owner?.kind == .replicaSet { owner = owner?.ownerUID.flatMap { byUID[$0] } }
                if let owner, visible.contains(where: { $0.id == owner.id }) { edges.append(Edge(from: owner.id, to: pod.id)) }
                for service in visible where service.kind == .service && service.namespace == pod.namespace && !service.selector.isEmpty {
                    if service.selector.allSatisfy({ pod.labels[$0.key] == $0.value }) { edges.append(Edge(from: service.id, to: pod.id, isRouting: true)) }
                }
            }
        }
    }
}
