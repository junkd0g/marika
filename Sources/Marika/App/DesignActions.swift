import AppKit
import MarikaCore

extension AppModel {
    func openDesignLink(_ link: DesignSourceLink, projectID: UUID) async throws {
        guard link.isValid, let project = project(id: projectID) else { throw DesignToolError("This design link is no longer valid.") }
        if selectedProject?.id != projectID { openProject(project, tab: .design) }
        switch link.kind {
        case .file, .symbol:
            let root = project.url.standardizedFileURL.resolvingSymlinksInPath()
            let file = root.appendingPathComponent(link.target).standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(root.path + "/"),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw DesignToolError("The linked file is missing or outside this project.")
            }
            let declaration = link.kind == .symbol ? try await designSymbol(link, projectID: projectID) : nil
            let line = declaration.map { $0.position.line + 1 } ?? link.line ?? 1
            guard self.project(id: projectID)?.path == project.path else { throw DesignToolError("The linked project is no longer available.") }
            if selectedProject?.id != projectID { openProject(project, tab: .code) }
            selectRepository(project.url, project: project)
            switchPanel(.code)
            let workspace = editor(for: self.project(id: projectID) ?? project)
            await editorRestorations[projectID]?[project.url.path]?.value
            await workspace.open(link.target)
            guard workspace.selectedDocument?.path == link.target else {
                throw DesignToolError(workspace.errorMessage ?? "The linked file could not be opened.")
            }
            if let document = workspace.selectedDocument, !document.isModified { await workspace.reload(document) }
            workspace.reveal(line: line, column: declaration.map { $0.position.character + 1 } ?? 1, length: declaration?.length ?? 0)
        case .endpoint:
            guard let endpoint = project.apiCollection?.endpoints.first(where: { $0.id == link.target }) else {
                throw DesignToolError("This API endpoint is no longer in the project's collection.")
            }
            let workspace = apiWorkspaces[projectID] ?? APIWorkspace()
            apiWorkspaces[projectID] = workspace; workspace.select(endpoint, project: project)
            switchPanel(.api)
        case .documentation:
            browser(for: project).navigate(link.target); switchPanel(.browser)
        }
    }

    func designTickets(projectID: UUID, elements: Set<UUID>) -> [SpaceTicket] {
        guard let project = project(id: projectID), let space = workspace.spaces.first(where: { $0.id == project.spaceID }) else { return [] }
        return space.tickets.filter {
            !$0.archived && $0.projectID == projectID && $0.designSource?.projectID == projectID
                && !Set($0.designSource?.elementIDs ?? []).isDisjoint(with: elements)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func createDesignTicket(_ draft: DesignTicketDraft) async throws -> UUID {
        var updated = workspace
        let ticket = try updated.createTicket(from: draft)
        editSpaceContent { $0 = updated }
        guard await save() else {
            if let location = ticketLocation(ticket.id) {
                editSpaceContent { workspace in
                    if let index = workspace.spaces.firstIndex(where: { $0.id == location.spaceID }) {
                        workspace.spaces[index].tickets.removeAll { $0.id == ticket.id }
                    }
                }
            }
            throw DesignToolError("The ticket couldn't be saved. Your design and draft are kept.")
        }
        return ticket.id
    }

    func saveDesignVersion(projectID: UUID, name: String) throws {
        guard let project = project(id: projectID) else { throw DesignToolError("Project unavailable") }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw DesignToolError("Name this version before saving it.") }
        let version = DesignVersion(name: title, document: design(for: project).document)
        updateProject(projectID) { $0.designVersions = Array((($0.designVersions ?? []) + [version]).suffix(10)) }
    }

    func restoreDesignVersion(projectID: UUID, versionID: UUID) throws {
        guard let project = project(id: projectID), let version = project.designVersions?.first(where: { $0.id == versionID }) else {
            throw DesignToolError("This saved version is unavailable.")
        }
        let editor = design(for: project)
        for node in editor.document.nodes where node.isLocked {
            guard version.document.node(node.id) == node else { throw DesignToolError("Unlock changed layers before restoring this version.") }
        }
        editor.edit { $0 = version.document }
        designCanvases[projectID]?.externalChange()
    }
}
