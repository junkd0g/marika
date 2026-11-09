import Foundation
import MarikaCore
import Observation

@MainActor @Observable final class TaskVerificationWorkspace {
    enum Freshness { case checking, current, outdated, unverified }
    private weak var model: AppModel?
    let sessionID: UUID
    var running = false
    private(set) var freshness: Freshness = .checking
    private(set) var freshnessDetail: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false

    init(model: AppModel, sessionID: UUID) { self.model = model; self.sessionID = sessionID }
    private var controller: SessionController? { model?.controllers[sessionID] }
    private var root: URL? {
        guard let meta = controller?.meta ?? model?.workspace.sessions.first(where: { $0.id == sessionID }) else { return nil }
        return meta.agentTask?.workspace.map { URL(fileURLWithPath: $0.workingPath) } ?? model?.project(for: meta)?.url
    }
    var hasUnsavedInputs: Bool {
        guard let root, let model else { return false }
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return model.repositoryEditors.values.contains { editors in
            editors.values.contains { editor in
                editor.modifiedDocuments.contains { document in
                    editor.root.appendingPathComponent(document.path).standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(base)
                }
            }
        }
    }
    var status: Freshness {
        if hasUnsavedInputs || controller?.isBusy == true { return .outdated }
        if let controller, let record = controller.meta.taskVerification,
           let summary = TaskCompletionSummary(items: controller.items), !summary.includes(record) { return .outdated }
        return freshness
    }
    var detail: String? {
        if hasUnsavedInputs { return "Save your edits before running checks. Tests use the files on disk." }
        if controller?.isBusy == true { return "The agent is changing this task. Run checks when it finishes." }
        if status == .outdated { return "Code changed since this run. Run checks again for the current files." }
        return freshnessDetail
    }
    var label: String {
        switch status {
        case .checking: "Checking freshness…"
        case .outdated: "Outdated"
        case .unverified: "Freshness unverified"
        case .current: controller?.meta.taskVerification?.succeeded == true ? "Passed" : controller?.meta.taskVerification?.succeeded == false ? "Failed" : "Incomplete"
        }
    }
    var passed: Bool { status == .current && controller?.meta.taskVerification?.succeeded == true }

    /// Runs only while a result is visible. Content hashes also detect external edits
    /// with unchanged file size/mtime; no background polling for closed projects.
    func monitor() async {
        if !running { freshness = .checking }
        while !Task.isCancelled {
            await refreshFreshness()
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }
    func refreshFreshness() async {
        guard !running, !refreshing, let record = controller?.meta.taskVerification else { return }
        guard let snapshot = record.snapshot, snapshot.version == 1 else {
            freshness = .unverified
            freshnessDetail = record.snapshotIssue ?? "This older result has no code fingerprint. Run checks again to verify the current files."
            return
        }
        guard let root else { freshness = .unverified; freshnessDetail = "The checked project is unavailable."; return }
        refreshing = true
        defer { refreshing = false }
        do {
            let current = try await VerificationSnapshot.capture(at: root)
            guard !Task.isCancelled, !running, controller?.meta.taskVerification == record else { return }
            freshness = current == snapshot ? .current : .outdated
            freshnessDetail = nil
        } catch is CancellationError {} catch {
            guard !running, controller?.meta.taskVerification == record else { return }
            freshness = .unverified; freshnessDetail = error.localizedDescription
        }
    }
    func run() {
        guard !running, !hasUnsavedInputs, let model, let controller, !controller.isBusy,
              controller.meta.agentTask?.workspace?.status != .discarded, let project = model.project(for: controller.meta), project.runtime == nil,
              let root else { return }
        let scope = ReviewTestScope.resolve(paths: [], root: root)
        let title = scope.framework + " · " + scope.title
        let context = ToolContext(root: root, environment: model.toolEnvironment)
        let changeCount = controller.changeCount
        let turnID = controller.items.last { if case .turnEnd = $0.content { true } else { false } }?.id
        running = true; freshness = .checking; freshnessDetail = nil
        task = Task {
            defer { running = false; task = nil }
            var before: VerificationSnapshot?
            var issue: String?
            do { before = try await VerificationSnapshot.capture(at: root) }
            catch { issue = error.localizedDescription }
            var record: TaskVerificationRecord
            do {
                try Task.checkCancellation()
                let result = try await scope.run(in: context)
                try Task.checkCancellation()
                record = TaskVerificationRecord(command: title, output: result.output, succeeded: result.succeeded, snapshot: before, snapshotIssue: issue)
            } catch is CancellationError {
                record = TaskVerificationRecord(command: title, output: "Test run stopped.", succeeded: nil, snapshot: before, snapshotIssue: issue)
            } catch {
                record = TaskVerificationRecord(command: title, output: error.localizedDescription, succeeded: nil, snapshot: before, snapshotIssue: issue)
            }
            let after = try? await VerificationSnapshot.capture(at: root)
            let currentTurnID = controller.items.last { if case .turnEnd = $0.content { true } else { false } }?.id
            if controller.isBusy || controller.changeCount != changeCount || currentTurnID != turnID || hasUnsavedInputs || (before != nil && before != after) {
                record.succeeded = nil
                record.output = "The task or its files changed while checks were running. Run them again for the latest work.\n\n" + record.output
                freshness = .outdated
            } else { freshness = before != nil && before == after ? .current : .unverified }
            freshnessDetail = issue
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
