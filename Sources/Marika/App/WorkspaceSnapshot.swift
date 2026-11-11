import MarikaCore

/// Captures UI state before persistence yields to asynchronous disk writes.
extension AppModel {
    func workspaceSnapshot() -> Workspace {
        var workspace = workspace
        workspace.selectedProjectID = selectedProject?.id
        for index in workspace.projects.indices {
            let id = workspace.projects[index].id
            var saved = workspace.projects[index].layout ?? ProjectLayout()
            saved.panel = projectTabs[id] ?? saved.panel
            for (path, editor) in repositoryEditors[id] ?? [:] where !editor.isRestoring {
                var repositoryLayout = path == workspace.projects[index].path ? saved : workspace.projects[index].repositoryLayouts?[path] ?? ProjectLayout()
                repositoryLayout.files = editor.savedFiles
                repositoryLayout.selectedFile = editor.selectedDocument?.path
                repositoryLayout.showsNavigator = editor.showsNavigator
                repositoryLayout.navigatorWidth = editor.navigatorWidth
                if path == workspace.projects[index].path { saved = repositoryLayout }
                else { workspace.projects[index].repositoryLayouts = (workspace.projects[index].repositoryLayouts ?? [:]).merging([path: repositoryLayout]) { _, new in new } }
            }
            if let editor = editors[id], !editor.isRestoring, editor.root == workspace.projects[index].url {
                saved.files = editor.savedFiles
                saved.selectedFile = editor.selectedDocument?.path
                saved.showsNavigator = editor.showsNavigator
                saved.navigatorWidth = editor.navigatorWidth
            }
            if let browser = browsers[id] {
                saved.browserURLs = browser.pages.map { $0.url?.absoluteString ?? "" }
                saved.browserIndex = browser.pages.firstIndex { $0.id == browser.selectedPageID } ?? 0
                saved.browserViewport = browser.viewport
                saved.browserLibrary = browser.library
            }
            if selectedSession?.projectID == id { saved.showsInspector = showsInspector }
            workspace.projects[index].layout = saved
        }
        return workspace
    }
}
