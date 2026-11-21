import Foundation

public enum ContainerMetric: String, Codable, CaseIterable, Sendable {
    case cpu, memory, restarts, latency, errorRate
    public var title: String { switch self {
    case .cpu: "CPU cores"; case .memory: "Memory bytes"; case .restarts: "Restarts"
    case .latency: "Latency (ms)"; case .errorRate: "Error rate (%)"
    } }
}
public struct ContainerMetricPoint: Identifiable, Codable, Hashable, Sendable {
    public var id: String { resourceID + metric.rawValue + String(date.timeIntervalSince1970) }
    public var resourceID: String
    public var metric: ContainerMetric
    public var date: Date
    public var value: Double
    public init(resourceID: String, metric: ContainerMetric, date: Date, value: Double) {
        self.resourceID = resourceID; self.metric = metric; self.date = date; self.value = value
    }
}
/// Bounded, ephemeral samples. A missing value is never replaced with zero.
public struct ContainerMetricHistory: Sendable {
    public private(set) var points: [ContainerMetricPoint] = []
    public init() {}
    public mutating func append(_ incoming: [ContainerMetricPoint], now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-3600)
        var values = Dictionary(points.filter { $0.date >= cutoff }.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for point in incoming where point.value.isFinite && point.value >= 0 && point.date >= cutoff {
            values[point.id] = point
        }
        points = Array(values.values.sorted { $0.date < $1.date }.suffix(12_000))
    }
}
public struct ContainerMetricsConnection: Codable, Hashable, Sendable {
    public var authentication = ContainerLogConnection()
    public var latencyQuery = ""
    public var errorQuery = ""
    public init() {}
}
public enum ContainerMetricDecoding {
    public static func quantity(_ text: String) -> Double? {
        let units: [(String, Double)] = [("KiB",1024),("MiB",1_048_576),("GiB",1_073_741_824),("TiB",1_099_511_627_776),
            ("Ki",1024),("Mi",1_048_576),("Gi",1_073_741_824),("Ti",1_099_511_627_776),
            ("kB",1000),("MB",1e6),("GB",1e9),("TB",1e12),("n",1e-9),("u",1e-6),("m",1e-3),("k",1000),("M",1e6),("G",1e9),("B",1)]
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed: Double?
        if let unit = units.first(where: { value.hasSuffix($0.0) }) { parsed = Double(value.dropLast(unit.0.count)).map { $0 * unit.1 } }
        else { parsed = Double(value) }
        guard let parsed, parsed.isFinite, parsed >= 0 else { return nil }; return parsed
    }
    public static func docker(_ data: Data, resources: [ContainerResource], date: Date) throws -> [ContainerMetricPoint] {
        try ContainerDecoding.records(data).flatMap { row -> [ContainerMetricPoint] in
            guard let resource = resources.first(where: { item in
                item.kind == .container && (row["ID"]?.string == item.uid || row["Name"]?.string == item.name || item.uid.hasPrefix(row["Container"]?.string ?? "--"))
            }) else { return [] }
            var points: [ContainerMetricPoint] = []
            if let cpu = Double((row["CPUPerc"]?.string ?? "").replacingOccurrences(of: "%", with: "")), cpu.isFinite, cpu >= 0 {
                points.append(ContainerMetricPoint(resourceID: resource.id, metric: .cpu, date: date, value: cpu / 100))
            }
            if let memory = quantity(String((row["MemUsage"]?.string ?? "").split(separator: "/").first ?? "")) {
                points.append(ContainerMetricPoint(resourceID: resource.id, metric: .memory, date: date, value: memory))
            }
            return points
        }
    }
    public static func kubernetes(_ data: Data, resources: [ContainerResource], date: Date) throws -> [ContainerMetricPoint] {
        let json = try JSONValue(parsing: data)
        return (json["items"]?.array ?? []).flatMap { item -> [ContainerMetricPoint] in
            guard let pod = resources.first(where: { $0.kind == .pod && $0.name == item["metadata"]?["name"]?.string && $0.namespace == item["metadata"]?["namespace"]?.string }) else { return [] }
            let containers = item["containers"]?.array ?? []
            return [(ContainerMetric.cpu, "cpu"), (.memory, "memory")].compactMap { metric, key in
                let values = containers.compactMap { $0["usage"]?[key]?.string.flatMap(quantity) }
                guard !values.isEmpty, values.count == containers.count else { return nil }
                return ContainerMetricPoint(resourceID: pod.id, metric: metric, date: date, value: values.reduce(0, +))
            }
        }
    }
}
