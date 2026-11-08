import Foundation
import MarikaCore
import Observation

@MainActor @Observable final class TaskVerificationWorkspace {
    private weak var model: AppModel?
    let sessionID: UUID
    var running = false
    @ObservationIgnored private var task: Task<Void, Never>?
    init(model: AppModel, sessionID: UUID) { self.model = model; self.sessionID = sessionID }
    func run() {
        guard !running, let model, let controller = model.controllers[sessionID], !controller.isBusy,
              controller.meta.agentTask?.workspace?.status != .discarded, let project = model.project(for: controller.meta), project.runtime == nil else { return }
        let root = controller.meta.agentTask?.workspace.map { URL(fileURLWithPath: $0.workingPath) } ?? project.url
        let scope = ReviewTestScope.resolve(paths: [], root: root)
        let title = scope.framework + " · " + scope.title
        let context = ToolContext(root: root, environment: model.toolEnvironment)
        running = true
        task = Task {
            defer { running = false; task = nil }
            let record: TaskVerificationRecord
            do {
                let result = try await scope.run(in: context)
                try Task.checkCancellation()
                record = TaskVerificationRecord(command: title, output: result.output, succeeded: result.succeeded)
            } catch is CancellationError {
                record = TaskVerificationRecord(command: title, output: "Test run stopped.", succeeded: nil)
            } catch {
                record = TaskVerificationRecord(command: title, output: error.localizedDescription, succeeded: nil)
            }
            controller.recordVerification(record)
        }
    }
    func stop() { task?.cancel() }
}

extension AppModel {
    func taskVerification(for id: UUID) -> TaskVerificationWorkspace {
        if let value = taskVerifications[id] { return value }
        let value = TaskVerificationWorkspace(model: self, sessionID: id)
        taskVerifications[id] = value
        return value
    }
}
