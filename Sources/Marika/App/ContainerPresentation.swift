import MarikaCore

enum ContainerViewMode: String, CaseIterable {
    case map = "Map", list = "List", logs = "Logs", health = "Health"
}

enum ContainerLogBackend: String, CaseIterable {
    case runtime = "Runtime", loki = "Loki"
}
