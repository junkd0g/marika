import Foundation

extension ContainerCLI {
    public func metricSamples(_ provider: ContainerProvider, target: ContainerTarget, namespace: String, resources: [ContainerResource]) async throws -> [ContainerMetricPoint] {
        let date = Date()
        if provider == .docker {
            let result = try await execute(ContainerPlans.docker(target, ["stats", "--no-stream", "--no-trunc", "--format", "{{json .}}"], timeout: 15))
            return try ContainerMetricDecoding.docker(result.data, resources: resources, date: date)
        }
        let path: String
        if namespace == "*" { path = "/apis/metrics.k8s.io/v1beta1/pods" }
        else {
            guard ContainerPlans.name(namespace) else { throw ContainerHubError("Choose a valid namespace for metrics.") }
            path = "/apis/metrics.k8s.io/v1beta1/namespaces/" + namespace + "/pods"
        }
        let result = try await execute(ContainerPlans.kubectl(target, ["get", "--raw", path], timeout: 15))
        return try ContainerMetricDecoding.kubernetes(result.data, resources: resources, date: date)
    }
}
