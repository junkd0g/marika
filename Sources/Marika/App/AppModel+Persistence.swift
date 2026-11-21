import AppKit
import MarikaCore

extension AppModel {
    // MARK: Persistence

    func scheduleSave() {
        // Coalesce changes without resetting the deadline: continuous edits or several
        // streaming agents must still reach disk while work is in progress.
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            await self.save()
        }
    }

    @discardableResult
    func save() async -> Bool {
        guard isReady, !workspaceLoadFailed else { return false }
        // Serialize snapshots so an older write cannot finish after a newer one.
        while let active = activeSave {
            _ = await active.task.value
            if activeSave?.id == active.id { activeSave = nil }
        }
        let id = UUID()
        let task = Task { await persistSnapshot() }
        activeSave = (id, task)
        let succeeded = await task.value
        if activeSave?.id == id { activeSave = nil }
        return succeeded
    }

    private func persistSnapshot() async -> Bool {
        // Capture one snapshot before yielding, so edits made during a write remain dirty.
        let workspace = workspaceSnapshot()
        let dirty = dirtyTranscripts
        dirtyTranscripts.removeAll()
        let transcripts = dirty.compactMap { id in
            controllers[id].map { (id, $0.items) }
        }
        var errors: [String] = []
        do { try await store.save(workspace) }
        catch { errors.append(error.localizedDescription) }
        for (id, items) in transcripts {
            do { try await store.saveTranscript(items, for: id) }
            catch {
                dirtyTranscripts.insert(id)
                errors.append(error.localizedDescription)
            }
        }
        if !errors.isEmpty { storageError = errors.joined(separator: "\n\n") }
        else if unreadableTranscripts.isEmpty { storageError = nil }
        return errors.isEmpty
    }

    func collectRecoveryNotices() async {
        let notices = await store.takeRecoveryNotices()
        if !notices.isEmpty { storageRecoveryNotice = notices.joined(separator: "\n") }
    }

    func showSavedData() { NSWorkspace.shared.activateFileViewerSelecting([store.root]) }

    func retryStorage() async {
        if workspaceLoadFailed {
            isReady = false
            await bootstrap()
        } else {
            for id in unreadableTranscripts { await open(id) }
            guard unreadableTranscripts.isEmpty else { return }
            do {
                try await store.retryFailedSaves()
                await collectRecoveryNotices()
            } catch {
                storageError = error.localizedDescription
                return
            }
            await save()
        }
    }

    @discardableResult
    func shutdown(saveChanges: Bool = true) async -> Bool {
        isShuttingDown = true
        for flow in signIns.values { flow.stopWaiting() }
        if workspaceLoadFailed { return true }
        for controller in controllers.values { dirtyTranscripts.insert(controller.id) }
        if saveChanges, !(await save()) { isShuttingDown = false; return false }
        scheduler?.cancel()
        saveTask?.cancel()
        saveTask = nil
        let tools = Array(projectRuntimeTools.values)
        for project in tools { await project.stopBackgroundWork() }
        await withTaskGroup(of: Void.self) { group in
            for controller in controllers.values {
                group.addTask { await controller.shutdown() }
            }
        }
        for controller in controllers.values where activeCheckpoints[controller.id] != nil { await completeTurn(controller) }
        for controller in controllers.values { dirtyTranscripts.insert(controller.id) }
        let saved = saveChanges ? await save() : true
        // Keep the browser usable if a failed final save returns the user to the app.
        if saved {
            for project in tools { project.disconnect() }
            folderAccess.releaseUnused(in: [])
        } else { isShuttingDown = false; startScheduler() }
        return saved
    }
}
