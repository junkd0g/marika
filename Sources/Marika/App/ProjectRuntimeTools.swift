import Foundation
import MarikaCore
import Observation

/// The running tools attached to a single open project.
@MainActor @Observable final class ProjectRuntimeTools {
    var api: APIWorkspace?
    var browser: BrowserWorkspace?
    var containers: ContainerWorkspace?
    var debugTask: Task<Void, Never>?
    var ide: [URL: IDEWorkspace] = [:]
    var pipeline: ProjectPipelineRunner?
    var preview: ProjectPreview?
    var qa: QAWorkspace?
    var terminal: ProjectTerminal?

    func stopBackgroundWork() async {
        pipeline?.stop()
        containers?.stop()
        preview?.stop()
        let task = debugTask
        task?.cancel()
        await qa?.stopReplay()
        for workspace in Array(ide.values) { await workspace.shutdown() }
        await task?.value
    }

    func disconnect() {
        api?.cancelAll()
        browser?.stop()
        terminal?.shutdown()
    }

    func shutdown() async {
        await stopBackgroundWork()
        disconnect()
    }
}

extension AppModel {
    func runtimeTools(for id: UUID) -> ProjectRuntimeTools {
        if let existing = projectRuntimeTools[id] { return existing }
        let tools = ProjectRuntimeTools()
        projectRuntimeTools[id] = tools
        return tools
    }
}
