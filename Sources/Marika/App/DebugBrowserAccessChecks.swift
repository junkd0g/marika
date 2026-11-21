#if DEBUG
import Foundation
import MarikaCore

@MainActor enum DebugBrowserAccessChecks {
    static func run(_ model: AppModel) async throws {
        guard DebugFixtureSettings.value("MARIKA_DATA") != nil, let project = model.selectedProject else {
            throw BrowserError.message("Use an isolated browser-access fixture.")
        }
        let browser = model.browser(for: project)
        let page = browser.selectedPage!
        let external = URL(string: "https://accounts.google.com/")!
        guard !browser.agentAccessEnabled, !browser.agentAllowed(external) else {
            throw BrowserError.message("Agent access was enabled before consent.")
        }
        browser.agentAccessEnabled = true
        guard browser.agentAccessEnabled, browser.agentAllowed(external),
              browser.agentAllowed(URL(string: "https://other.example/redirect")!),
              !browser.agentAllowed(URL(string: "javascript:alert(1)")!),
              !browser.agentAllowed(URL(fileURLWithPath: "/etc/hosts")) else {
            throw BrowserError.message("Default access or browser address boundaries are incorrect.")
        }
        // Set metadata only; this check must never load an external service.
        page.url = external; page.title = "Fixture account page"
        let visible = await browser.performTool(["name": "browser_tabs"])
        guard visible["content"]?[0]?["text"]?.string?.contains("Fixture account page") == true else {
            throw BrowserError.message("Default access hid an external tab.")
        }
        browser.agentAccessEnabled = false
        let hidden = await browser.performTool(["name": "browser_tabs"])
        let blocked = await browser.performTool(["name": "browser_snapshot"])
        guard hidden["content"]?[0]?["text"]?.string?.contains("Fixture account page") == false,
              blocked["isError"]?.bool == true, !browser.canUseAgent else {
            throw BrowserError.message("Explicitly turning access off did not block the bridge.")
        }
        // Also exercise restore when no browser tabs have been saved yet.
        let restored = BrowserWorkspace(root: project.url)
        defer { restored.stop() }
        var empty = ProjectLayout(); empty.browserAgentAccessEnabled = false
        restored.restore(empty)
        guard !restored.agentAccessEnabled else { throw BrowserError.message("Empty-tab restore reset the access choice.") }

        page.load(project.url.appendingPathComponent("index.html"))
        model.openProject(project, tab: .browser)
        guard await model.save(), let saved = try await model.store.loadWorkspace().projects.first(where: { $0.id == project.id }),
              saved.layout?.browserAgentAccessEnabled == false else {
            throw BrowserError.message("The app did not save the browser-access choice.")
        }
    }

    static func restored(_ model: AppModel) throws {
        guard let project = model.selectedProject, model.projectTabs[project.id] == .browser,
              model.projectRuntimeTools[project.id]?.browser?.agentAccessEnabled == false else {
            throw BrowserError.message("Browser access did not survive an app restart.")
        }
    }
}
#endif
