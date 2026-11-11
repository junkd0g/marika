import Foundation

public enum DesignTemplate: String, CaseIterable, Sendable {
    case context, services, request, deployment
    public var title: String { switch self { case .context: "System context"; case .services: "Service architecture"; case .request: "Request flow"; case .deployment: "Deployment" } }
    public var summary: String { switch self {
    case .context: "People, your system, and external dependencies"
    case .services: "Client, gateway, services, messages, and storage"
    case .request: "A numbered request from client to database"
    case .deployment: "Application and data tiers inside an environment"
    } }
    public func makeDocument() -> DesignDocument {
        var doc = DesignDocument(); doc.title = title
        func node(_ component: DesignComponent, _ name: String, _ x: Double, _ y: Double) -> UUID {
            let id = doc.addComponent(component, centeredAt: CGPoint(x: x + 118, y: y + 50))
            doc.update([id]) { $0.name = name; $0.text = name; $0.description = "Proposed template element. " + ($0.description ?? "") }
            return id
        }
        func frame(_ name: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double) {
            let id = doc.add(.frame, in: CGRect(x: x, y: y, width: width, height: height))
            doc.update([id]) { $0.name = name; $0.stroke = DesignColor.gray; $0.cornerRadius = 14; $0.description = "Proposed " + name + " boundary. Adapt to the actual project." }
        }
        func edge(_ a: UUID, _ b: UUID, _ text: String, _ style: DesignFlow = .request) {
            if let id = doc.connect(a, b, label: text) { doc.updateConnection(id) { $0.style = style == .request ? nil : style } }
        }
        switch self {
        case .context:
            frame("System boundary", 310, -50, 310, 360)
            let user = node(.client, "User", 0, 80), app = node(.service, "Your system", 350, 80)
            let external = node(.external, "External service", 730, 0), identity = node(.external, "Identity provider", 730, 180)
            edge(user, app, "Uses"); edge(app, external, "Calls"); edge(app, identity, "Authenticates")
        case .services:
            let client = node(.client, "Web / mobile app", 0, 180), gateway = node(.gateway, "Gateway", 330, 180)
            frame("Application", 640, -40, 310, 570)
            let api = node(.api, "API service", 680, 0), queue = node(.queue, "Jobs", 680, 200), worker = node(.worker, "Worker", 680, 400)
            frame("Data", 990, -40, 310, 380)
            let db = node(.database, "Database", 1030, 0), cache = node(.cache, "Cache", 1030, 200)
            edge(client, gateway, "HTTPS"); edge(gateway, api, "Request"); edge(api, db, "Read / write", .data)
            edge(api, cache, "Lookup", .data); edge(api, queue, "Enqueue", .event); edge(queue, worker, "Consume", .event)
        case .request:
            let client = node(.client, "Client", 0, 0), api = node(.api, "API", 330, 0)
            let service = node(.service, "Application service", 660, 0), db = node(.database, "Database", 990, 0)
            edge(client, api, "1 · Request"); edge(api, service, "2 · Validate & execute"); edge(service, db, "3 · Query", .data)
            let note = doc.add(.text, in: CGRect(x: 330, y: 180, width: 640, height: 70))
            doc.update([note]) { $0.text = "Add response handling, timeouts, retries, and failure paths for your project."; $0.fontSize = 16 }
        case .deployment:
            frame("Production — proposed", 280, -60, 1050, 520)
            frame("Application tier", 320, -10, 620, 390)
            frame("Data tier", 990, -10, 300, 390)
            let client = node(.client, "Client", 0, 130), gateway = node(.gateway, "Load balancer", 360, 130)
            let app = node(.service, "App instance", 660, 40), worker = node(.worker, "Worker instance", 660, 230)
            let db = node(.database, "Database instance", 1020, 130)
            edge(client, gateway, "TLS"); edge(gateway, app, "HTTP"); edge(app, db, "Private network", .data); edge(worker, db, "Private network", .data)
        }
        return doc
    }
}

extension DesignDocument {
    @discardableResult public mutating func insertTemplate(_ template: DesignTemplate) -> Set<UUID> {
        var incoming = template.makeDocument()
        let delta = visibleBounds.map { $0.maxX + 100 - (incoming.visibleBounds?.minX ?? 0) } ?? 0
        for index in incoming.nodes.indices { incoming.nodes[index].x += delta }
        if nodes.isEmpty { title = incoming.title }
        nodes += incoming.nodes; connections = (connections ?? []) + (incoming.connections ?? [])
        return Set(incoming.nodes.map(\.id))
    }
}
