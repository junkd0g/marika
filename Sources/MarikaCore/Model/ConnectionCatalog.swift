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
    public var command: String? = nil
    public var arguments: [String] = []
    public var setup: String? = nil
    public var requiresClientID = false
    public var usesToken = false
    public var setupLabel: String {
        command != nil ? "Local CLI setup" : usesToken ? "Personal access token · Keychain" : requiresClientID ? "Browser sign-in · Client ID required" : usesOAuth ? "Browser sign-in" : "Public documentation"
    }
    public var server: MCPServerConfiguration {
        if let command { return MCPServerConfiguration(name: id, configuration: ["command": .string(command), "args": .array(arguments.map(JSONValue.string))]) }
        var fields: [String: JSONValue] = ["type": "http", "url": .string(endpoint)]
        if usesToken { fields["marikaAuthKind"] = "token" }
        return MCPServerConfiguration(name: id, configuration: .object(fields))
    }
    public func matches(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { word in
            (name + " " + category + " " + summary).localizedStandardContains(String(word))
        }
    }
    public func configuredServer(in servers: [MCPServerConfiguration]) -> MCPServerConfiguration? {
        servers.first {
            if let command { return $0.configuration["command"]?.string == command && $0.configuration["args"]?.array?.compactMap(\.string) == arguments }
            return $0.configuration["url"]?.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
    }
    // Nothing is installed or contacted by browsing the catalog. gws recipes pin its documented MCP release.
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
        .init(id: "github", name: "GitHub", category: "Code", summary: "Search repositories, inspect issues and work with pull requests.",
              endpoint: "https://api.githubcopilot.com/mcp/", documentation: "https://github.com/github/github-mcp-server/blob/main/docs/remote-server.md",
              permissions: "Access follows the repositories and permissions on your GitHub token. Start with read-only permissions; add write permissions only for actions you need. The token is stored in Keychain, never project JSON.", usesOAuth: false,
              setup: "Create a fine-grained GitHub personal access token for the repositories you want to use. Paste it below. Organization policy may require approval. Sign out removes the local token; revoke it at GitHub to invalidate it.", usesToken: true),
        .init(id: "slack", name: "Slack", category: "Messages", summary: "Search conversations, read threads and work with your Slack workspace.",
              endpoint: "https://mcp.slack.com/mcp", documentation: "https://docs.slack.dev/ai/slack-mcp-server/",
              permissions: "Can read or post to Slack according to approved app scopes. Workspace admin approval may be required. Slack requires an approved internal or directory app; dynamic client registration is unavailable.", usesOAuth: true,
              setup: "Use your approved PKCE-enabled Slack app's OAuth client ID. Register the exact loopback redirect shown below (default http://127.0.0.1:8765/oauth/slack) in that app. Use user scopes supported by Slack's desktop OAuth flow. Follow the setup guide, then connect. The chosen local port must be free.", requiresClientID: true),
    ] + [google("gmail", name: "Gmail", category: "Email", summary: "Search messages and work with email through Google Workspace CLI."),
         google("calendar", name: "Google Calendar", category: "Calendar", summary: "Inspect calendars and manage events through Google Workspace CLI."),
         google("drive", name: "Google Drive", category: "Files", summary: "Search and manage Drive files through Google Workspace CLI."),
         google("sheets", name: "Google Sheets", category: "Spreadsheets", summary: "Read and update spreadsheet data through Google Workspace CLI.")]

    private static func google(_ service: String, name: String, category: String, summary: String) -> Self {
        .init(id: "google-" + service, name: name, category: category, summary: summary,
              endpoint: "Google Workspace CLI · " + service, documentation: "https://github.com/googleworkspace/cli/tree/v0.5.0#authentication",
              permissions: "Uses the Google account and scopes authorized in gws for \(service). Tools may read and change account data. Credentials are managed by gws, separately from Marika. Review scopes before signing in.", usesOAuth: false,
              command: "npx", arguments: ["--yes", "--package=@googleworkspace/cli@0.5.0", "gws", "mcp", "-s", service],
              setup: "This recipe pins gws 0.5.0, which includes its MCP server. The googleworkspace project is not an officially supported Google product. Node.js 18+ is required. Test or agent connection downloads the pinned package if needed. First configure your own Google Cloud Desktop OAuth client using the linked guide, then sign in in Terminal:\n\nnpx --yes --package=@googleworkspace/cli@0.5.0 gws auth login -s \(service)\n\nReturn here and use Test connection. Adding this recipe alone does not sign in or grant access.")
    }
}
