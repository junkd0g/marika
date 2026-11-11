import Foundation
import Testing
@testable import MarikaCore

private actor ContainerRecorder {
    var commands: [ContainerCommand] = []
    var manifests: [Data] = []
    func append(_ command: ContainerCommand) {
        commands.append(command)
        if let index = command.arguments.firstIndex(of: "-f"), command.arguments.indices.contains(index + 1),
           let bytes = try? Data(contentsOf: URL(fileURLWithPath: command.arguments[index + 1])) { manifests.append(bytes) }
    }
}

struct ContainerHubTests {
    private let docker = ContainerTarget(name: "desktop-linux", endpoint: "unix:///var/run/docker.sock")
    private let kube = ContainerTarget(name: "test-cluster")
    private var resource: ContainerResource {
        var value = ContainerResource(id: "kube:one", name: "api", kind: .deployment)
        value.namespace = "testing"; value.uid = "one"; value.replicas = 2; return value
    }
    private func root() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true); return path
    }
    @Test func dockerRecordsPreservePortsGroupsAndState() throws {
        let data = Data(#"{"ID":"abcdef123456","Names":"api","Image":"example/api:dev","State":"running","Status":"Up 2 minutes (healthy)","Ports":"0.0.0.0:8080->80/tcp","Networks":"demo_default","Labels":"com.docker.compose.project=demo,app=api"}"#.utf8)
        let items = try ContainerDecoding.dockerContainers(data)
        #expect(items.count == 1 && items[0].condition == .ready && items[0].stack == "demo")
        #expect(items[0].localPort == 8080 && items[0].targetPort == 80 && items[0].networks == ["demo_default"])
        let contexts = try ContainerDecoding.dockerContexts(Data(#"{"Name":"desktop-linux","DockerEndpoint":"unix:///var/run/docker.sock","Current":true}"#.utf8))
        #expect(contexts[0].isCurrent && contexts[0].isLocalDocker)
        let exited = try ContainerDecoding.dockerContainers(Data(#"{"ID":"abcdef654321","Names":"worker","State":"exited","Status":"Exited (1) 10 minutes ago"}"#.utf8))
        #expect(exited[0].condition == .failed)
    }
    @Test func kubernetesTopologyUsesOwnershipAndSelectorsWithinNamespace() throws {
        let data = Data(#"{"items":[{"kind":"Deployment","metadata":{"name":"api","namespace":"app","uid":"d"},"spec":{"replicas":2},"status":{"readyReplicas":1}},{"kind":"ReplicaSet","metadata":{"name":"api-rs","namespace":"app","uid":"r","ownerReferences":[{"uid":"d","controller":true}]}},{"kind":"Pod","metadata":{"name":"api-one","namespace":"app","uid":"p","labels":{"app":"api"},"ownerReferences":[{"uid":"r","controller":true}]},"spec":{"nodeName":"node-one","containers":[{"image":"api:dev","env":[{"name":"PASSWORD","value":"not-for-display"}]}]},"status":{"phase":"Running","containerStatuses":[{"ready":false,"restartCount":4,"state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}},{"kind":"Service","metadata":{"name":"api","namespace":"app","uid":"s"},"spec":{"selector":{"app":"api"},"ports":[{"port":80}]}},{"kind":"Service","metadata":{"name":"other","namespace":"other","uid":"x"},"spec":{"selector":{"app":"api"}}}]}"#.utf8)
        let items = try ContainerDecoding.kubernetes(data)
        let pod = try #require(items.first { $0.uid == "p" })
        #expect(pod.condition == .failed && pod.restarts == 4 && pod.node == "node-one" && pod.image == "api:dev")
        #expect(!pod.detail.contains("not-for-display"))
        let map = ContainerTopology(resources: items, provider: .kubernetes)
        #expect(map.edges.contains { $0.from == "kube:d" && $0.to == "kube:p" })
        #expect(map.edges.contains { $0.from == "kube:s" && $0.to == "kube:p" })
        #expect(map.edges.filter(\.isRouting).count == 1)
        #expect(!map.edges.contains { $0.from == "kube:x" })
        #expect(!map.nodes.contains { $0.id == "kube:r" })
    }
    @Test func actionsAlwaysCarryTheirTargetAndNamespace() throws {
        let command = try ContainerPlans.kubeAction("scale", resource: resource, target: kube, replicas: 3)
        #expect(command.arguments == ["--context", "test-cluster", "--request-timeout=20s", "--namespace", "testing", "scale", "deployment/api", "--replicas=3", "--current-replicas=2"])
        #expect(throws: ContainerHubError.self) { try ContainerPlans.kubeAction("scale", resource: resource, target: kube, replicas: -1) }
        #expect(throws: ContainerHubError.self) { try ContainerPlans.docker(ContainerTarget(name: "--host=other"), ["ps"]) }
        let run = try ContainerPlans.runImage("nginx:alpine", name: "web", hostPort: 8080, containerPort: 80, projectID: UUID(), target: docker)
        #expect(Array(run.arguments.prefix(2)) == ["--context", "desktop-linux"] && run.arguments.contains("127.0.0.1:8080:80"))
        #expect(throws: ContainerHubError.self) { try ContainerPlans.runImage("nginx;touch /tmp/no", name: "web", hostPort: nil, containerPort: nil, projectID: UUID(), target: docker) }
        #expect(throws: ContainerHubError.self) { try ContainerPlans.runImage("nginx", name: "web", hostPort: 0, containerPort: 80, projectID: UUID(), target: docker) }
    }
    @Test func portForwardOnlyBindsLoopback() throws {
        var pod = resource; pod.kind = .pod
        let command = try ContainerPlans.portForward(pod, target: kube, localPort: 8080, remotePort: 80)
        #expect(command.arguments.contains("--address=127.0.0.1") && command.arguments.contains("8080:80"))
        #expect(throws: ContainerHubError.self) { try ContainerPlans.portForward(resource, target: kube, localPort: 8080, remotePort: 80) }
    }
    @Test func manifestAppliesExactlyTheReviewedBytesAndPreservesExitOneDiff() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("deploy.yaml"), recorder = ContainerRecorder()
        let original = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: original\n"
        try original.write(to: path, atomically: true, encoding: .utf8)
        let service = ContainerCLI(root: root, environment: [:], runner: { command in
            await recorder.append(command)
            return ContainerCommandResult(status: command.arguments.contains("diff") ? 1 : 0, output: "reviewed change")
        })
        let review = try await service.previewManifest("deploy.yaml", target: kube, namespace: "testing")
        try "changed after preview".write(to: path, atomically: true, encoding: .utf8)
        _ = try await service.apply(review)
        let snapshots = await recorder.manifests, commands = await recorder.commands
        #expect(snapshots == [Data(original.utf8), Data(original.utf8)])
        #expect(commands.allSatisfy { $0.arguments.contains("test-cluster") && $0.arguments.contains("testing") })
        for command in commands { let index = command.arguments.firstIndex(of: "-f")!; #expect(!FileManager.default.fileExists(atPath: command.arguments[index + 1])) }
        await #expect(throws: (any Error).self) { try await service.previewManifest("../outside.yaml", target: kube, namespace: "testing") }
    }
    @Test func replacedResourcesAreRejectedBeforeMutation() async throws {
        let service = ContainerCLI(root: URL(fileURLWithPath: "/tmp"), environment: [:], runner: { _ in ContainerCommandResult(output: "another-uid") })
        await #expect(throws: ContainerHubError.self) { try await service.verify(resource, target: kube) }
    }
    @Test func localClustersUseDedicatedKubeconfigWithoutChangingGlobalContext() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ContainerRecorder()
        let service = ContainerCLI(root: root, environment: [:], runner: { command in await recorder.append(command); return ContainerCommandResult() })
        let cluster = LocalCluster(name: "marika-test", dockerContext: "desktop-linux")
        _ = try await service.createCluster(cluster, directory: root)
        let commands = await recorder.commands, create = try #require(commands.last)
        #expect(create.arguments == ["create", "cluster", "--name", "marika-test", "--kubeconfig", cluster.configuration(in: root).path, "--wait", "120s"])
        #expect(create.environment["DOCKER_CONTEXT"] == "desktop-linux")
        #expect(commands.allSatisfy { !$0.arguments.contains("use-context") })
        var project = Project(path: root.path); var settings = ContainerHubSettings(); settings.clusters = [cluster]; project.containerHub = settings
        #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)).containerHub == settings)
    }
}
