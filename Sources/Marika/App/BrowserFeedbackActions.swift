import AppKit
import MarikaCore

extension AppModel {
    func attachBrowserFeedback(_ text: String, image: Data, project: Project) async {
        guard let meta = selectedSession?.projectID == project.id ? selectedSession : workspace.conversation(for: project.id) else { return }
        await open(meta.id)
        guard let session = controllers[meta.id] else { return }
        let directory = store.attachmentsDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(UUID().uuidString + ".png")
            try image.write(to: url, options: .atomic)
            session.draft += (session.draft.isEmpty ? "" : "\n\n") + text
            session.draftImages.append(ImageAttachment(path: url.path, mediaType: "image/png"))
            selectedSessionID = session.id
            projectTabs[project.id] = .conversation
            composerFocusRequest = UUID()
        } catch { browsers[project.id]?.errorMessage = "Couldn't attach screenshot: \(error.localizedDescription)" }
    }
}
