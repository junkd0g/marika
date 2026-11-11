import Foundation

/// Editable architecture components. The role survives copying, saving, and agent updates.
public enum DesignComponent: String, Codable, CaseIterable, Sendable {
    case client, gateway, service, api, worker, database, cache, queue, storage, external

    public var title: String {
        switch self {
        case .client: "Client app"
        case .gateway: "API gateway"
        case .service: "Service"
        case .api: "API"
        case .worker: "Worker"
        case .database: "Database"
        case .cache: "Cache"
        case .queue: "Message queue"
        case .storage: "Object storage"
        case .external: "External system"
        }
    }

    public var symbol: String {
        switch self {
        case .client: "laptopcomputer"
        case .gateway: "arrow.triangle.branch"
        case .service: "server.rack"
        case .api: "curlybraces"
        case .worker: "gearshape.2"
        case .database: "cylinder.split.1x2"
        case .cache: "bolt"
        case .queue: "tray.2"
        case .storage: "externaldrive"
        case .external: "cloud"
        }
    }

    public var summary: String {
        switch self {
        case .client: "Web, mobile, or desktop application"
        case .gateway: "Route requests to backend services"
        case .service: "An application responsibility or boundary"
        case .api: "An HTTP, RPC, or event interface"
        case .worker: "Process background jobs"
        case .database: "Persist structured application data"
        case .cache: "Keep reusable or temporary results"
        case .queue: "Deliver messages between components"
        case .storage: "Store files, blobs, and media"
        case .external: "A dependency outside this system"
        }
    }

    public var group: String {
        switch self {
        case .service, .api, .worker: "Compute"
        case .database, .cache, .queue, .storage: "Data"
        case .client, .gateway, .external: "Clients & network"
        }
    }

    public var accent: DesignColor {
        let hex: String = switch self {
        case .client: "4F67CF"
        case .gateway: "9360B8"
        case .service, .api: "6254D9"
        case .worker: "426B9F"
        case .database: "23836B"
        case .cache: "AF741F"
        case .queue: "B06A36"
        case .storage: "277D9D"
        case .external: "6B7280"
        }
        return DesignColor(hex: hex) ?? .blue
    }

    public func makeNode(centeredAt center: CGPoint) -> DesignNode {
        var node = DesignNode(kind: .rectangle, name: title, x: center.x - 118, y: center.y - 50, width: 236, height: 100)
        node.component = self
        node.text = title
        node.description = "Architecture placeholder: " + summary + ". Implementation details have not been specified."
        let tint = accent
        node.fill = DesignColor(0.94 + tint.red * 0.06, 0.94 + tint.green * 0.06, 0.94 + tint.blue * 0.06)
        node.stroke = DesignColor(tint.red, tint.green, tint.blue, 0.45)
        node.cornerRadius = 12
        node.fontSize = 16
        return node
    }
}

extension DesignDocument {
    @discardableResult
    public mutating func addComponent(_ component: DesignComponent, centeredAt center: CGPoint) -> UUID {
        var node = component.makeNode(centeredAt: center)
        var suffix = 2
        while nodes.contains(where: { $0.name == node.name }) {
            node.name = component.title + " \(suffix)"
            suffix += 1
        }
        node.text = node.name
        node.normalize()
        nodes.append(node)
        return node.id
    }
}
