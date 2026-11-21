import AppKit
import MarikaCore

extension AppModel {
    func attachBrowserFeedback(_ text: String, image: Data, project: Project) async {
        guard let meta = selectedSession?.projectID == project.id ? selectedSession : workspace.conversation(for: project.id) else { return }
        await open(meta.id)
        guard let session = controllers[meta.id] else { return }
        do {
            let attachment = try await store.images.savePNG(image)
            session.draft += (session.draft.isEmpty ? "" : "\n\n") + text
            session.draftImages.append(attachment)
            selectedSessionID = session.id
            projectTabs[project.id] = .conversation
            composerFocusRequest = UUID()
        } catch { projectRuntimeTools[project.id]?.browser?.errorMessage = "Couldn't attach screenshot: \(error.localizedDescription)" }
    }
}
