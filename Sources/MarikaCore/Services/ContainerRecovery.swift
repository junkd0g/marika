import Foundation

extension ContainerCLI {
    public func object(_ resource: ContainerResource, target: ContainerTarget) async throws -> JSONValue {
        guard ContainerPlans.resourceName(resource.name), ContainerPlans.name(resource.namespace) else { throw ContainerHubError("Invalid resource name.") }
        let command = try ContainerPlans.kubectl(target, namespace: resource.namespace, ["get", resource.kind.kubectlName, resource.name, "-o", "json"])
        let value = try JSONValue(parsing: await execute(command).data)
        guard value["metadata"]?["uid"]?.string == resource.uid else { throw ContainerHubError("This resource was replaced. Refresh and review it again.") }
        return value
    }

    public func revisions(_ resource: ContainerResource, target: ContainerTarget) async throws -> [ContainerRevision] {
        guard resource.kind == .deployment else { throw ContainerHubError("Revision review is available for Deployments.") }
        try await verify(resource, target: target)
        let result = try await execute(ContainerPlans.kubectl(target, namespace: resource.namespace, ["get", "replicasets", "-o", "json"]))
        return try JSONValue(parsing: result.data)["items"]?.array?.compactMap { value in
            guard value["metadata"]?["ownerReferences"]?.array?.contains(where: { $0["uid"]?.string == resource.uid && $0["controller"]?.bool == true }) == true,
                  let revision = value["metadata"]?["annotations"]?["deployment.kubernetes.io/revision"]?.string.flatMap(Int.init), revision > 0,
                  let name = value["metadata"]?["name"]?.string, let uid = value["metadata"]?["uid"]?.string,
                  let template = value["spec"]?["template"] else { return nil }
            return ContainerRevision(revision: revision, name: name, uid: uid,
                images: template["spec"]?["containers"]?.array?.compactMap { $0["image"]?.string }.joined(separator: ", ") ?? "", template: template)
        }.sorted { $0.revision > $1.revision } ?? []
    }

    public func prepareRollback(_ resource: ContainerResource, target: ContainerTarget, revision: ContainerRevision) async throws -> ContainerRecoveryReview {
        guard resource.kind == .deployment, revision.revision > 0 else { throw ContainerHubError("Select a Deployment revision.") }
        let source = try await object(resource, target: target)
        let current = source["metadata"]?["annotations"]?["deployment.kubernetes.io/revision"]?.string.flatMap(Int.init)
        guard current != revision.revision else { throw ContainerHubError("That revision is already current.") }
        guard let selected = try await revisions(resource, target: target).first(where: { $0.uid == revision.uid && $0.revision == revision.revision }), selected.template == revision.template,
              let spec = source["spec"] else { throw ContainerHubError("The revision changed. Reload history before reviewing.") }
        return ContainerRecoveryReview(kind: .rollback, source: resource, target: target, title: "Roll back " + resource.name + " to revision \(revision.revision)",
            explanation: "Restores the entire pod template from this revision, including its configuration. Replica count stays unchanged. The Deployment will roll out replacement pods.",
            before: Self.templateSummary(spec["template"]), after: Self.templateSummary(revision.template), sourceSpec: spec, revision: revision)
    }

    public func prepareRetry(_ resource: ContainerResource, target: ContainerTarget) async throws -> ContainerRecoveryReview {
        guard resource.kind == .job || resource.kind == .cronJob else { throw ContainerHubError("Select a Job or CronJob.") }
        let source = try await object(resource, target: target)
        guard let originalSpec = source["spec"], var spec = resource.kind == .cronJob ? originalSpec["jobTemplate"]?["spec"] : originalSpec,
              spec["template"] != nil else { throw ContainerHubError("The job template is missing.") }
        guard spec["manualSelector"]?.bool != true, spec["managedBy"] == nil || spec["managedBy"]?.string == "kubernetes.io/job-controller" else {
            throw ContainerHubError("This Job uses custom controller ownership. Run it through its owning controller.")
        }
        var fields = spec.object ?? [:], template = spec["template"]?.object ?? [:]
        var metadata = template["metadata"]?.object ?? [:], labels = metadata["labels"]?.object ?? [:]
        fields.removeValue(forKey: "selector"); fields.removeValue(forKey: "manualSelector"); fields["suspend"] = .bool(false)
        for key in ["controller-uid", "job-name", "batch.kubernetes.io/controller-uid", "batch.kubernetes.io/job-name"] { labels.removeValue(forKey: key) }
        for key in ["uid", "resourceVersion", "creationTimestamp", "managedFields", "ownerReferences", "name", "generateName", "namespace"] { metadata.removeValue(forKey: key) }
        metadata["labels"] = .object(labels); template["metadata"] = .object(metadata); fields["template"] = .object(template); spec = .object(fields)
        let name = String(resource.name.prefix(42)).trimmingCharacters(in: CharacterSet(charactersIn: ".-")) + "-retry-" + UUID().uuidString.prefix(8).lowercased()
        let job: JSONValue = ["apiVersion": "batch/v1", "kind": "Job", "metadata": ["name": .string(name), "namespace": .string(resource.namespace),
            "annotations": ["app.marika/retry-source": .string(resource.kind.rawValue + "/" + resource.name), "app.marika/retry-source-uid": .string(resource.uid)]], "spec": spec]
        return ContainerRecoveryReview(kind: .retry, source: resource, target: target, title: resource.kind == .cronJob ? "Run " + resource.name + " now" : "Retry " + resource.name,
            explanation: "Creates a new independent Job named \(name). The original resource and its schedule stay unchanged. This runs the work again and can repeat its writes or notifications.",
            before: resource.status, after: Self.templateSummary(spec["template"]), sourceSpec: originalSpec, newJobName: name, jobData: try job.serialized())
    }

    public func recover(_ review: ContainerRecoveryReview) async throws -> ContainerCommandResult {
        let current = try await object(review.source, target: review.target)
        guard current["spec"] == review.sourceSpec else { throw ContainerHubError("The workload configuration changed. Review the recovery again.") }
        switch review.kind {
        case .retry:
            guard let data = review.jobData, let name = review.newJobName,
                  try JSONValue(parsing: data)["metadata"]?["name"]?.string == name else { throw ContainerHubError("The reviewed Job is invalid.") }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("marika-retry-" + UUID().uuidString + ".json")
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            defer { try? FileManager.default.removeItem(at: file) }
            return try await execute(ContainerPlans.kubectl(review.target, namespace: review.source.namespace, ["create", "-f", file.path], timeout: 90))
        case .rollback:
            guard let revision = review.revision,
                  try await revisions(review.source, target: review.target).contains(where: { $0.uid == revision.uid && $0.revision == revision.revision && $0.template == revision.template }) else {
                throw ContainerHubError("The selected revision is no longer available. Review history again.")
            }
            return try await execute(ContainerPlans.kubectl(review.target, namespace: review.source.namespace,
                ["rollout", "undo", "deployment/" + review.source.name, "--to-revision=\(revision.revision)"], timeout: 90))
        }
    }

    private static func templateSummary(_ template: JSONValue?) -> String {
        let spec = template?["spec"]
        func containers(_ key: String) -> [String] { (spec?[key]?.array ?? []).map { value in
            let names = value["env"]?.array?.compactMap { $0["name"]?.string }.joined(separator: ", ") ?? ""
            return (value["name"]?.string ?? "Container") + ": " + (value["image"]?.string ?? "Unknown image") + (names.isEmpty ? "" : "\nEnvironment names: " + names)
        } }
        return (containers("initContainers") + containers("containers") + ["Restart policy: " + (spec?["restartPolicy"]?.string ?? "Always"),
            "Service account: " + (spec?["serviceAccountName"]?.string ?? "default")]).joined(separator: "\n\n")
    }
}
