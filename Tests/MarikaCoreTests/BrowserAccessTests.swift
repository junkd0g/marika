import Foundation
import Testing
@testable import MarikaCore

struct BrowserAccessTests {
    @Test func newAndLegacyLayoutsRequireSharingConsent() throws {
        #expect(!ProjectLayout().browserAgentAccessEnabled)
        let legacy = try JSONDecoder().decode(ProjectLayout.self, from: Data(#"{"browserAgentAccessEnabled":true,"browserURLs":["https://example.com"],"browserViewport":"Mobile"}"#.utf8))
        #expect(!legacy.browserAgentAccessEnabled)
        #expect(legacy.browserURLs == ["https://example.com"])
        #expect(legacy.browserViewport == "Mobile")
    }

    @Test func explicitAccessChoicePersistsWithoutChangingOtherProjects() throws {
        var first = Project(path: "/tmp/first")
        first.layout = ProjectLayout()
        first.layout?.browserAgentAccessEnabled = true
        let second = Project(path: "/tmp/second")
        let workspace = Workspace(projects: [first, second])
        let restored = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        #expect(restored.projects[0].layout?.browserAgentAccessEnabled == true)
        #expect(!(restored.projects[1].layout ?? ProjectLayout()).browserAgentAccessEnabled)
    }
}
