import Foundation
import MarikaCore
import Observation

@MainActor @Observable final class DesignHealthModel {
    var issues: [DesignHealthIssue] = []
    var isRunning = false
    var checkedAt: Date?
    var checkedKey: String?
    var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    func contextKey(_ canvas: DesignCanvasModel) -> String {
        let project = canvas.app?.project(id: canvas.projectID)
        let endpoints = project?.apiCollection?.endpoints.map(\.id).sorted().joined(separator: "\n") ?? ""
        let documents = canvas.app?.repositoryEditors[canvas.projectID]?.values.flatMap(\.modifiedDocuments)
            .map { $0.path + ":\($0.revision)" }.sorted().joined(separator: ",") ?? ""
        return ((try? DesignTools.revision(of: canvas.doc)) ?? "") + endpoints + documents
    }
    func isStale(_ canvas: DesignCanvasModel) -> Bool { checkedKey != nil && checkedKey != contextKey(canvas) }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; isRunning = false }

    func refresh(_ canvas: DesignCanvasModel) {
        cancel()
        guard let app = canvas.app, let project = app.project(id: canvas.projectID) else { error = "Project unavailable."; return }
        let token = generation, document = canvas.doc, key = contextKey(canvas)
        let endpoints = Set(project.apiCollection?.endpoints.map(\.id) ?? [])
        isRunning = true; error = nil
        task = Task { [weak self] in
            do {
                let issues = try await DesignHealth.scan(document, endpointIDs: endpoints, file: { path in
                    if project.runtime?.kind == .ssh { return .unavailable("Remote files cannot be checked by the local Design audit.") }
                    return await DesignHealth.file(path, root: project.url)
                }, symbols: { path in
                    do { return .success(try await app.designSymbols(projectID: project.id, path: path)) }
                    catch let error as SymbolLookupError { return .failure(error) }
                    catch { return .failure(.unavailable(error.localizedDescription)) }
                })
                guard let self, generation == token, !Task.isCancelled else { return }
                self.issues = issues; checkedAt = Date(); checkedKey = key; isRunning = false; task = nil
            } catch {
                guard let self, generation == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription; isRunning = false; task = nil
            }
        }
    }
}
