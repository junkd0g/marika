import AppKit
import MarikaCore
import Observation

@MainActor @Observable final class AgentReviewWorkspace {
    private weak var model: AppModel?
    let projectID: UUID
    let sessionID: UUID
    private let service: AgentWorktrees
    var isOpen = true
    var review: AgentChangeReview?
    var selectedPath: String?
    var selectedHunkID: String?
    var busy = false
    var error: String?
    var notice: String?
    var feedback = ""
    var feedbackHunk: AgentReviewHunk?
    var showsFeedback = false
    var testsRunning = false
    var testResult: TestExecution?
    var testScope: ReviewTestScope?
    var testError: String?
    var testSnapshot: VerificationSnapshot?
    var testOutdated = false
    var testFreshnessIssue: String?
    var testIsCurrent: Bool { testSnapshot != nil && !testOutdated && testFreshnessIssue == nil && !agentIsBusy }
    var showsTestOutput = false
    @ObservationIgnored private var testTask: Task<Void, Never>?

    init(model: AppModel, projectID: UUID, sessionID: UUID) {
        self.model = model; self.projectID = projectID; self.sessionID = sessionID
        service = model.worktreeService
    }
    var session: SessionMeta? { model?.controllers[sessionID]?.meta ?? model?.workspace.sessions.first { $0.id == sessionID } }
    var workspace: AgentWorkspace? { session?.agentTask?.workspace }
    var project: Project? { model?.project(id: projectID) }
    var agentIsBusy: Bool { model?.controllers[sessionID]?.isBusy == true }
    var canDecide: Bool { !busy && !agentIsBusy && !testsRunning }
    var hunks: [AgentReviewHunk] { review?.hunks ?? [] }
    var fileHunks: [AgentReviewHunk] { hunks.filter { $0.path == selectedPath } }
    var accepted: Int { workspace?.acceptedChanges ?? 0 }
    var rejected: Int { workspace?.rejectedChanges ?? 0 }

    func refresh() async {
        guard !busy, !agentIsBusy, let workspace, let project else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let result = try await service.review(workspace, project: project.url)
            if review?.patch != result.patch, testResult != nil { testOutdated = true }
            setReview(result)
        } catch { self.error = error.localizedDescription }
    }
    private func setReview(_ value: AgentChangeReview) {
        review = value
        if !value.files.contains(where: { $0.path == selectedPath }) { selectedPath = value.files.first?.path }
        if !value.hunks.contains(where: { $0.id == selectedHunkID }) { selectedHunkID = fileHunks.first?.id }
    }
    func selectFile(_ path: String) { selectedPath = path; selectedHunkID = fileHunks.first?.id }
    func move(_ offset: Int) {
        guard !hunks.isEmpty else { return }
        let current = hunks.firstIndex { $0.id == selectedHunkID } ?? 0
        let item = hunks[(current + offset + hunks.count) % hunks.count]
        selectedPath = item.path; selectedHunkID = item.id
    }
    private func protectDrafts(paths: [String], root: String) throws {
        guard let model else { return }
        let destinations = Set(paths.map { URL(fileURLWithPath: root).appendingPathComponent($0).standardizedFileURL.resolvingSymlinksInPath().path })
        for editors in model.repositoryEditors.values {
            for editor in editors.values {
                for document in editor.modifiedDocuments where destinations.contains(editor.root.appendingPathComponent(document.path).standardizedFileURL.resolvingSymlinksInPath().path) {
                    throw AgentWorktreeError(message: "Save or discard your edits to \(document.path) before accepting this change.")
                }
            }
        }
    }
    func decide(_ decision: AgentWorktrees.Decision, hunk: AgentReviewHunk) async {
        guard canDecide, let review, var workspace, let project, let model else { return }
        busy = true; error = nil; notice = nil
        defer { busy = false }
        do {
            if decision == .accept { try protectDrafts(paths: [hunk.path], root: review.projectRoot ?? project.path) }
            let result = try await service.decide(decision, hunkID: hunk.id, review: review, workspace: workspace, project: project.url)
            workspace.baseCommit = result.baseCommit
            if decision == .accept { workspace.acceptedChanges = accepted + 1 }
            else { workspace.rejectedChanges = rejected + 1; testOutdated = true }
            workspace.status = result.isEmpty ? .reviewed : .ready
            model.updateAgentWorkspace(workspace, sessionID: sessionID)
            setReview(result)
            notice = decision == .accept ? "Accepted change in \(hunk.path)" : "Rejected change in \(hunk.path)"
            if decision == .accept { await refreshEditors() }
            _ = await model.save()
        } catch { self.error = error.localizedDescription }
    }
    func acceptRemaining() async {
        guard canDecide, let review, !review.isEmpty, var workspace, let project, let model else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try protectDrafts(paths: review.files.map(\.path), root: review.projectRoot ?? project.path)
            workspace.baseCommit = try await service.apply(review, workspace: workspace, to: project.url)
            workspace.acceptedChanges = accepted + review.hunks.count
            workspace.status = .reviewed
            model.updateAgentWorkspace(workspace, sessionID: sessionID)
            setReview(try await service.review(workspace, project: project.url))
            notice = "Accepted the remaining changes"
            await refreshEditors()
            _ = await model.save()
        } catch { self.error = error.localizedDescription }
    }
    private func refreshEditors() async {
        guard let model else { return }
        for editor in model.repositoryEditors[projectID]?.values ?? [:].values { await editor.refresh() }
    }
    func runTests(hunk: AgentReviewHunk? = nil) {
        guard canDecide, let workspace, let model else { return }
        let root = URL(fileURLWithPath: workspace.workingPath)
        let prefix = String(workspace.workingPath.dropFirst(workspace.rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let paths = (hunk.map { [$0.path] } ?? review?.files.map(\.path) ?? []).compactMap { path -> String? in
            if prefix.isEmpty { return path }
            return path.hasPrefix(prefix + "/") ? String(path.dropFirst(prefix.count + 1)) : nil
        }
        let scope = ReviewTestScope.resolve(paths: paths, root: root)
        testScope = scope; testsRunning = true; testResult = nil; testError = nil; testSnapshot = nil; testOutdated = false; testFreshnessIssue = nil; showsTestOutput = true
        let patch = review?.patch
        let context = ToolContext(root: root, environment: model.toolEnvironment)
        testTask = Task { [weak self] in
            guard let self else { return }
            defer { testsRunning = false }
            do {
                do { testSnapshot = try await VerificationSnapshot.capture(at: root) }
                catch { testFreshnessIssue = error.localizedDescription }
                try Task.checkCancellation()
                let result = try await scope.run(in: context)
                try Task.checkCancellation()
                let current = try await service.review(workspace, project: project?.url)
                let after = try? await VerificationSnapshot.capture(at: root)
                testResult = result
                if current.patch != patch || agentIsBusy || (testSnapshot != nil && testSnapshot != after) {
                    testSnapshot = nil
                    testOutdated = true
                    testError = "The reviewed code changed while tests ran. Run them again for the current changes."
                }
            } catch is CancellationError { testError = "Test run stopped." }
            catch { testError = error.localizedDescription }
        }
    }
    func monitorTestFreshness() async {
        while !Task.isCancelled, isOpen {
            if !testsRunning, testResult != nil, let snapshot = testSnapshot, let workspace {
                do {
                    let current = try await VerificationSnapshot.capture(at: URL(fileURLWithPath: workspace.workingPath))
                    if !testsRunning, testSnapshot == snapshot {
                        testOutdated = current != snapshot
                        testFreshnessIssue = nil
                    }
                } catch is CancellationError { return }
                catch { testFreshnessIssue = error.localizedDescription }
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }
    func stopTests() { testTask?.cancel() }
    func beginFeedback(_ hunk: AgentReviewHunk? = nil) { feedbackHunk = hunk; showsFeedback = true }
    func sendFeedback() async {
        guard !busy, !agentIsBusy, let model, let project else { return }
        let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            await model.open(sessionID)
            guard let controller = model.controllers[sessionID], !controller.isBusy else { throw AgentWorktreeError(message: "Wait for this agent to finish before sending review feedback.") }
            var context = "Review feedback for your proposed changes in \(project.name). Continue in your isolated worktree and address this feedback. Accepted changes are already in the project; rejected changes were removed from the worktree.\n\n" + text
            if let hunk = feedbackHunk {
                context += "\n\nFile: \(hunk.path), proposed line \(hunk.newStart)\n\n" + String(String(decoding: hunk.patch, as: UTF8.self).prefix(20_000))
            }
            if let testResult, !testResult.succeeded { context += "\n\nLatest test output:\n" + String(testResult.output.suffix(6_000)) }
            controller.send(UserInput(text: context))
            feedback = ""; feedbackHunk = nil; showsFeedback = false
            notice = "Feedback sent to \(session?.agent.shortName ?? "the agent")"
        } catch { self.error = error.localizedDescription }
    }
    func close() { isOpen = false; model?.editors[projectID]?.focusEditor() }
    func openChat() { model?.openAgentChat(sessionID) }
}

extension AppModel {
    func openAgentReview(_ sessionID: UUID) async {
        guard let session = workspace.sessions.first(where: { $0.id == sessionID }), let project = project(for: session),
              let workspace = controllers[sessionID]?.meta.agentTask?.workspace ?? session.agentTask?.workspace, workspace.status != .discarded else { return }
        let review: AgentReviewWorkspace
        if let existing = agentReviews[project.id], existing.sessionID == sessionID { review = existing; review.isOpen = true }
        else { review = AgentReviewWorkspace(model: self, projectID: project.id, sessionID: sessionID); agentReviews[project.id] = review }
        if selectedProject?.id != project.id { openProject(project) }
        switchPanel(.code)
        await review.refresh()
    }
}
