import Foundation

public enum ContainerPlans {
    public static func value(_ value: String) -> Bool { !value.isEmpty && value.count <= 500 && !value.hasPrefix("-") && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
    public static func name(_ value: String) -> Bool { value.range(of: #"^[a-z0-9]([a-z0-9.-]{0,61}[a-z0-9])?$"#, options: .regularExpression) != nil }
    public static func resourceName(_ value: String) -> Bool { value.range(of: #"^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$"#, options: .regularExpression) != nil }
    public static func image(_ value: String) -> Bool { value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/@-]{0,499}$"#, options: .regularExpression) != nil }
    public static func docker(_ target: ContainerTarget, _ arguments: [String], timeout: Double = 30) throws -> ContainerCommand {
        guard value(target.name) else { throw ContainerHubError("Choose a Docker context first.") }
        return ContainerCommand("docker", ["--context", target.name] + arguments, timeout: timeout)
    }
    public static func kubectl(_ target: ContainerTarget, namespace: String? = nil, _ arguments: [String], timeout: Double = 30) throws -> ContainerCommand {
        guard value(target.name), target.kubeconfig.map(value) != false else { throw ContainerHubError("Choose a Kubernetes context first.") }
        var prefix = target.kubeconfig.map { ["--kubeconfig", $0] } ?? []
        prefix += ["--context", target.name, "--request-timeout=20s"]
        if let namespace { guard name(namespace) else { throw ContainerHubError("Choose a valid namespace.") }; prefix += ["--namespace", namespace] }
        return ContainerCommand("kubectl", prefix + arguments, timeout: timeout)
    }
    public static func dockerAction(_ action: String, resource: ContainerResource, target: ContainerTarget) throws -> ContainerCommand {
        guard resource.kind == .container, resource.uid.range(of: #"^[a-fA-F0-9]{12,64}$"#, options: .regularExpression) != nil,
              ["start", "stop", "restart", "logs"].contains(action) else { throw ContainerHubError("This container action is unavailable.") }
        return try docker(target, action == "logs" ? ["logs", "--tail", "200", "--timestamps", resource.uid] : [action, resource.uid], timeout: 60)
    }
    public static func kubeAction(_ action: String, resource: ContainerResource, target: ContainerTarget, replicas: Int? = nil) throws -> ContainerCommand {
        guard resourceName(resource.name), name(resource.namespace) else { throw ContainerHubError("Invalid Kubernetes resource name or namespace.") }
        let object = resource.kind.kubectlName + "/" + resource.name
        let arguments: [String]
        switch action {
        case "logs" where resource.kind == .pod:
            arguments = ["logs", object, "--all-containers=true", "--tail=200", "--timestamps=true", "--prefix=true"]
        case "restart" where resource.kind.restartable && resource.kind != .container:
            arguments = ["rollout", "restart", object]
        case "status" where resource.kind.restartable && resource.kind != .container:
            arguments = ["rollout", "status", object, "--watch=false"]
        case "scale" where resource.kind.scalable:
            guard let replicas, (0...1000).contains(replicas) else { throw ContainerHubError("Replicas must be between 0 and 1,000.") }
            arguments = ["scale", object, "--replicas=\(replicas)"] + (resource.replicas.map { ["--current-replicas=\($0)"] } ?? [])
        default: throw ContainerHubError("This Kubernetes action is unavailable.")
        }
        return try kubectl(target, namespace: resource.namespace, arguments, timeout: 60)
    }
    public static func podLogs(_ resource: ContainerResource, target: ContainerTarget, container: String?, previous: Bool) throws -> ContainerCommand {
        guard resource.kind == .pod, resourceName(resource.name), name(resource.namespace) else { throw ContainerHubError("Choose a pod for logs.") }
        var args = ["logs", "pod/" + resource.name, "--tail=300", "--timestamps=true", "--prefix=true"]
        if let container {
            guard resource.containers.contains(where: { $0.name == container }), resourceName(container) else { throw ContainerHubError("Choose a container from this pod.") }
            args += ["--container", container]
        } else {
            guard !previous else { throw ContainerHubError("Choose one container for previous logs.") }
            args += ["--all-containers=true"]
        }
        if previous { args += ["--previous=true"] }
        return try kubectl(target, namespace: resource.namespace, args, timeout: 40)
    }
    public static func runImage(_ reference: String, name: String, hostPort: Int?, containerPort: Int?, projectID: UUID, target: ContainerTarget) throws -> ContainerCommand {
        guard image(reference), self.name(name) else { throw ContainerHubError("Enter an image reference and a lowercase container name.") }
        var args = ["run", "--detach", "--name", name, "--label", "app.marika.project=" + projectID.uuidString]
        if hostPort != nil || containerPort != nil {
            guard let hostPort, let containerPort, (1...65535).contains(hostPort), (1...65535).contains(containerPort) else { throw ContainerHubError("Enter both ports, from 1 to 65,535.") }
            args += ["--publish", "127.0.0.1:\(hostPort):\(containerPort)"]
        }
        return try docker(target, args + [reference], timeout: 180)
    }
    public static func compose(_ action: String, file: String, root: URL, target: ContainerTarget) throws -> ContainerCommand {
        guard ["up", "down"].contains(action), value(file) else { throw ContainerHubError("Select a Compose file.") }
        _ = try APICollection.projectFile(file, root: root)
        return try docker(target, ["compose", "--project-directory", root.path, "-f", file, action] + (action == "up" ? ["--detach"] : []), timeout: 180)
    }
    public static func portForward(_ resource: ContainerResource, target: ContainerTarget, localPort: Int, remotePort: Int) throws -> ContainerCommand {
        guard [.pod, .service].contains(resource.kind), resourceName(resource.name), name(resource.namespace),
              (1...65535).contains(localPort), (1...65535).contains(remotePort) else { throw ContainerHubError("Select a pod or service and valid ports.") }
        return try kubectl(target, namespace: resource.namespace, ["port-forward", "--address=127.0.0.1", resource.kind.kubectlName + "/" + resource.name, "\(localPort):\(remotePort)"], timeout: 86_400)
    }
}


extension ContainerPlans {
    public static func logs(_ resource: ContainerResource, target: ContainerTarget, container: String?, since: Int, follow: Bool, previous: Bool = false) throws -> ContainerCommand {
        guard (1...604_800).contains(since), !(follow && previous) else { throw ContainerHubError("Choose a valid log time range. Previous logs cannot be followed.") }
        if resource.kind == .container {
            var command = try dockerAction("logs", resource: resource, target: target)
            command.arguments.insert(contentsOf: ["--since", "\(since)s"] + (follow ? ["--follow"] : []), at: command.arguments.count - 1)
            command.timeout = follow ? 86_400 : 40
            return command
        }
        var command = try podLogs(resource, target: target, container: container, previous: previous)
        command.arguments += ["--since=\(since)s"] + (follow ? ["--follow=true"] : [])
        command.timeout = follow ? 86_400 : 40
        return command
    }
}
