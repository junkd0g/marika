import Foundation

public enum ContainerDecoding {
    public static func records(_ data: Data) throws -> [JSONValue] {
        if data.isEmpty { return [] }
        if let value = try? JSONValue(parsing: data) { return value.array ?? [value] }
        return try String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map { try JSONValue(parsing: Data($0.utf8)) }
    }
    public static func dockerContexts(_ data: Data) throws -> [ContainerTarget] {
        try records(data).compactMap { value in
            guard let name = value["Name"]?.string, !name.isEmpty else { return nil }
            return ContainerTarget(name: name, endpoint: value["DockerEndpoint"]?.string ?? "", isCurrent: value["Current"]?.bool == true || value["Current"]?.string == "*")
        }
    }
    public static func dockerContainers(_ data: Data, stats: Data = Data()) throws -> [ContainerResource] {
        let metrics = (try? records(stats)) ?? []
        return try records(data).compactMap { value in
            guard let id = value["ID"]?.string, !id.isEmpty else { return nil }
            var item = ContainerResource(id: "docker:" + id, name: value["Names"]?.string ?? id, kind: .container)
            item.uid = id; item.image = value["Image"]?.string ?? ""; item.status = value["Status"]?.string ?? value["State"]?.string ?? "Unknown"
            let state = value["State"]?.string ?? ""
            let failed = item.status.contains("unhealthy") || state == "dead" || item.status.range(of: #"^Exited \([1-9][0-9]*\)"#, options: .regularExpression) != nil
            item.condition = failed ? .failed : item.status.contains("health: starting") ? .pending : state == "running" ? .ready : state == "exited" || state == "created" ? .stopped : .pending
            item.ports = value["Ports"]?.string ?? ""
            item.networks = (value["Networks"]?.string ?? "").split(separator: ",").map(String.init)
            for pair in (value["Labels"]?.string ?? "").split(separator: ",") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2 { item.labels[String(parts[0])] = String(parts[1]) }
            }
            item.stack = item.labels["com.docker.compose.project"] ?? ""
            if let regex = try? NSRegularExpression(pattern: #"(?:127\.0\.0\.1|0\.0\.0\.0|\[::\]|::):([0-9]+)->([0-9]+)/tcp"#),
               let match = regex.firstMatch(in: item.ports, range: NSRange(location: 0, length: (item.ports as NSString).length)) {
                item.localPort = Int((item.ports as NSString).substring(with: match.range(at: 1)))
                item.targetPort = Int((item.ports as NSString).substring(with: match.range(at: 2)))
            }
            if let stat = metrics.first(where: { $0["ID"]?.string == id || id.hasPrefix($0["Container"]?.string ?? "--") || $0["Name"]?.string == item.name }) {
                item.detail = "CPU " + (stat["CPUPerc"]?.string ?? "—") + " · Memory " + (stat["MemUsage"]?.string ?? "—")
            }
            return item
        }
    }
    public static func dockerImages(_ data: Data) throws -> [ContainerResource] {
        try records(data).compactMap { value in
            guard let id = value["ID"]?.string else { return nil }
            let name = (value["Repository"]?.string ?? "<none>") + ":" + (value["Tag"]?.string ?? "<none>")
            var item = ContainerResource(id: "image:" + id + ":" + name, name: name, kind: .image)
            item.uid = id; item.status = value["Size"]?.string ?? "Image"; item.detail = value["CreatedSince"]?.string ?? ""; item.condition = .configured
            return item
        }
    }
    public static func kubernetes(_ data: Data) throws -> [ContainerResource] {
        let doc = try JSONValue(parsing: data)
        let decoder = KubernetesDecoder()
        return (doc["items"]?.array ?? []).prefix(4_000).compactMap(decoder.resource)
    }

    /// Shares date parsing across resources while keeping each workload's status rules separate.
    private struct KubernetesDecoder {
        private let dates = ISO8601DateFormatter()

        private func date(_ value: JSONValue?) -> Date? {
            guard let text = value?.string else { return nil }
            dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = dates.date(from: text) { return date }
            dates.formatOptions = [.withInternetDateTime]; return dates.date(from: text)
        }

        func resource(_ value: JSONValue) -> ContainerResource? {
            guard let raw = value["kind"]?.string, let kind = ContainerResourceKind(rawValue: raw), kind != .container, kind != .image,
                  let name = value["metadata"]?["name"]?.string, let uid = value["metadata"]?["uid"]?.string else { return nil }
            let ns = value["metadata"]?["namespace"]?.string ?? "default"
            var item = ContainerResource(id: "kube:" + uid, name: name, kind: kind)
            item.uid = uid; item.namespace = ns
            let owners = value["metadata"]?["ownerReferences"]?.array ?? []
            let owner = owners.first { $0["controller"]?.bool == true } ?? owners.first
            item.ownerUID = owner?["uid"]?.string; item.ownerName = owner?["name"]?.string; item.ownerKind = owner?["kind"]?.string
            item.createdAt = date(value["metadata"]?["creationTimestamp"])
            item.startedAt = date(value["status"]?["startTime"]); item.finishedAt = date(value["status"]?["completionTime"])
            item.revision = value["metadata"]?["annotations"]?["deployment.kubernetes.io/revision"]?.string.flatMap(Int.init)
            let conditions = value["status"]?["conditions"]?.array ?? []
            if let failure = conditions.first(where: { ($0["type"]?.string == "Failed" || $0["type"]?.string == "FailureTarget" || $0["type"]?.string == "ReplicaFailure") && $0["status"]?.string == "True" || $0["type"]?.string == "Progressing" && $0["status"]?.string == "False" }) {
                item.failureReason = failure["reason"]?.string ?? ""; item.failureMessage = failure["message"]?.string ?? ""
            }
            item.labels = value["metadata"]?["labels"]?.object?.compactMapValues(\.string) ?? [:]
            item.selector = value["spec"]?["selector"]?["matchLabels"]?.object?.compactMapValues(\.string)
                ?? value["spec"]?["selector"]?.object?.compactMapValues(\.string) ?? [:]
            let podSpec = kind == .cronJob ? value["spec"]?["jobTemplate"]?["spec"]?["template"]?["spec"] : value["spec"]?["template"]?["spec"] ?? value["spec"]
            let containers = podSpec?["containers"]?.array ?? []
            item.image = containers.compactMap { $0["image"]?.string }.joined(separator: ", ")
            switch kind {
            case .pod: decodePod(value, podSpec: podSpec, into: &item)
            case .job: decodeJob(value, conditions: conditions, into: &item)
            case .cronJob: decodeCronJob(value, into: &item)
            case .service: decodeService(value, into: &item)
            default: decodeWorkload(value, into: &item)
            }
            return item
        }

        private func decodePod(_ value: JSONValue, podSpec: JSONValue?, into item: inout ContainerResource) {
            let containers = podSpec?["containers"]?.array ?? []
            let phase = value["status"]?["phase"]?.string ?? "Unknown"
            let statuses = value["status"]?["containerStatuses"]?.array ?? []
            let initial = value["status"]?["initContainerStatuses"]?.array ?? []
            let allStatuses = statuses + initial
            item.containers = (containers + (podSpec?["initContainers"]?.array ?? [])).compactMap { container in
                guard let name = container["name"]?.string else { return nil }
                let status = allStatuses.first { $0["name"]?.string == name }
                return ContainerLogSource(name: name, isInit: (podSpec?["initContainers"]?.array ?? []).contains { $0["name"]?.string == name }, restarts: status?["restartCount"]?.int ?? 0,
                    exitCode: status?["state"]?["terminated"]?["exitCode"]?.int, reason: status?["state"]?["waiting"]?["reason"]?.string ?? status?["state"]?["terminated"]?["reason"]?.string ?? "")
            }
            item.ready = statuses.filter { $0["ready"]?.bool == true }.count
            item.replicas = containers.count; item.restarts = allStatuses.reduce(0) { $0 + ($1["restartCount"]?.int ?? 0) }
            item.node = value["spec"]?["nodeName"]?.string ?? "Unscheduled"
            let initProblem = initial.first { $0["state"]?["waiting"] != nil || ($0["state"]?["terminated"]?["exitCode"]?.int ?? 0) != 0 }
            item.status = initProblem?["state"]?["waiting"]?["reason"]?.string ?? initProblem?["state"]?["terminated"]?["reason"]?.string
                ?? statuses.compactMap { $0["state"]?["waiting"]?["reason"]?.string ?? $0["state"]?["terminated"]?["reason"]?.string }.first ?? phase
            item.failureReason = item.status
            item.failureMessage = (initial + statuses).compactMap { $0["state"]?["waiting"]?["message"]?.string ?? $0["state"]?["terminated"]?["message"]?.string }.first ?? ""
            item.condition = phase == "Succeeded" ? .complete : phase == "Failed" || item.status.contains("CrashLoop") || item.status.contains("ImagePull") ? .failed
                : phase == "Running" && item.ready == containers.count && !containers.isEmpty ? .ready : .pending
            item.detail = "\(item.ready)/\(containers.count) ready · \(item.restarts) restarts"
            item.targetPort = containers.flatMap { $0["ports"]?.array ?? [] }.compactMap { $0["containerPort"]?.int }.first
        }

        private func decodeJob(_ value: JSONValue, conditions: [JSONValue], into item: inout ContainerResource) {
            let desired = value["spec"]?["completions"]?.int ?? 1
            item.replicas = desired; item.ready = value["status"]?["succeeded"]?.int ?? 0
            item.activeJobs = value["status"]?["active"]?.int ?? 0; item.failedAttempts = value["status"]?["failed"]?.int ?? 0
            item.isSuspended = value["spec"]?["suspend"]?.bool == true || condition("Suspended", in: conditions)
            if condition("Complete", in: conditions) { item.condition = .complete; item.status = "Completed" }
            else if condition("Failed", in: conditions) || condition("FailureTarget", in: conditions) { item.condition = .failed; item.status = "Failed" }
            else if item.isSuspended { item.condition = .suspended; item.status = "Suspended" }
            else if item.ready >= desired && item.activeJobs == 0 { item.condition = .complete; item.status = "Completed" }
            else { item.condition = .pending; item.status = item.activeJobs > 0 ? (item.failedAttempts > 0 ? "Retrying" : "Running") : "Pending" }
            if item.finishedAt == nil, item.condition == .failed || item.condition == .complete {
                item.finishedAt = date(conditions.first(where: { ["Complete", "Failed"].contains($0["type"]?.string ?? "") && $0["status"]?.string == "True" })?["lastTransitionTime"])
            }
            item.detail = "\(item.ready)/\(desired) completed · \(item.activeJobs) active · \(item.failedAttempts) failed attempts"
        }

        private func decodeCronJob(_ value: JSONValue, into item: inout ContainerResource) {
            item.schedule = value["spec"]?["schedule"]?.string ?? ""
            item.timeZone = value["spec"]?["timeZone"]?.string ?? "Controller time zone"
            item.isSuspended = value["spec"]?["suspend"]?.bool == true
            item.activeJobs = value["status"]?["active"]?.array?.count ?? 0
            item.lastScheduledAt = date(value["status"]?["lastScheduleTime"])
            item.lastSuccessfulAt = date(value["status"]?["lastSuccessfulTime"])
            item.condition = item.isSuspended ? .suspended : .configured
            item.status = item.isSuspended ? "Suspended" : item.activeJobs > 0 ? "\(item.activeJobs) active jobs" : "Scheduled"
            item.detail = item.schedule + " · " + item.timeZone
        }

        private func decodeService(_ value: JSONValue, into item: inout ContainerResource) {
            let ports = value["spec"]?["ports"]?.array ?? []
            item.targetPort = ports.first?["port"]?.int
            item.ports = ports.map { "\($0["port"]?.int ?? 0)/\($0["protocol"]?.string ?? "TCP")" }.joined(separator: ", ")
            item.status = value["spec"]?["type"]?.string ?? "ClusterIP"; item.condition = .configured
            item.detail = value["spec"]?["clusterIP"]?.string ?? ""
        }

        private func decodeWorkload(_ value: JSONValue, into item: inout ContainerResource) {
            let kind = item.kind
            let desired = kind == .daemonSet ? value["status"]?["desiredNumberScheduled"]?.int ?? 0 : value["spec"]?["replicas"]?.int ?? 1
            item.replicas = desired
            item.ready = kind == .daemonSet ? value["status"]?["numberReady"]?.int ?? 0 : value["status"]?["readyReplicas"]?.int ?? 0
            item.status = "\(item.ready)/\(desired) ready"
            item.condition = desired == 0 ? .stopped : item.ready >= desired ? .ready : .pending
            let generation = value["metadata"]?["generation"]?.int ?? 0
            let observed = value["status"]?["observedGeneration"]?.int ?? generation
            if !item.failureReason.isEmpty { item.condition = .failed; item.status = item.failureReason }
            else if observed < generation || (kind == .deployment && (value["status"]?["updatedReplicas"]?.int ?? item.ready) < desired) {
                item.condition = .pending; item.status += " · rolling out"
            }
        }

        private func condition(_ type: String, in conditions: [JSONValue]) -> Bool {
            conditions.contains { $0["type"]?.string == type && $0["status"]?.string == "True" }
        }
    }

    public static func events(_ data: Data) throws -> [ContainerEvent] {
        let doc = try JSONValue(parsing: data)
        let dates = ISO8601DateFormatter()
        let events = (doc["items"]?.array ?? []).compactMap { value -> ContainerEvent? in
            guard let id = value["metadata"]?["uid"]?.string else { return nil }
            let text = value["series"]?["lastObservedTime"]?.string ?? value["lastTimestamp"]?.string ?? value["eventTime"]?.string ?? value["metadata"]?["creationTimestamp"]?.string ?? ""
            dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var time = dates.date(from: text)
            if time == nil { dates.formatOptions = [.withInternetDateTime]; time = dates.date(from: text) }
            return ContainerEvent(id: id, resourceUID: value["involvedObject"]?["uid"]?.string ?? "", reason: value["reason"]?.string ?? "Event",
                                  message: value["message"]?.string ?? "", warning: value["type"]?.string == "Warning", timestamp: time)
        }
        return Array(events.sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }.suffix(200))
    }
}
