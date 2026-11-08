import Foundation

public struct ConnectionCatalogEntry: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let category: String
    public let summary: String
    public let endpoint: String
    public let documentation: String
    public let permissions: String
    public let usesOAuth: Bool
    public var server: MCPServerConfiguration {
        MCPServerConfiguration(name: id, configuration: ["type": "http", "url": .string(endpoint)])
    }
    public func matches(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { word in
            (name + " " + category + " " + summary).localizedStandardContains(String(word))
        }
    }
    public func configuredServer(in servers: [MCPServerConfiguration]) -> MCPServerConfiguration? {
        servers.first { $0.configuration["url"]?.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    }
    // Vendor-published remote endpoints. Nothing is installed or contacted by browsing the catalog.
    public static let entries: [Self] = [
        .init(id: "context7", name: "Context7", category: "Documentation", summary: "Look up current library documentation and code examples.",
              endpoint: "https://mcp.context7.com/mcp", documentation: "https://context7.com/docs/resources/all-clients",
              permissions: "Search public documentation. Queries are sent to Context7. Higher limits may require an API key in custom settings.", usesOAuth: false),
        .init(id: "linear", name: "Linear", category: "Issues", summary: "Search issues and manage project work with your account.",
              endpoint: "https://mcp.linear.app/mcp", documentation: "https://linear.app/docs/mcp",
              permissions: "Can read and change issues, projects and comments within your authorized account. Review the access requested during sign-in.", usesOAuth: true),
        .init(id: "notion", name: "Notion", category: "Knowledge", summary: "Find project knowledge and work with pages in Notion.",
              endpoint: "https://mcp.notion.com/mcp", documentation: "https://developers.notion.com/guides/mcp/get-started-with-mcp",
              permissions: "Can search, read and change content you authorize in Notion. Choose the workspace and access during sign-in.", usesOAuth: true),
    ]
}
