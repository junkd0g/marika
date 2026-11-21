import Foundation
import MarikaCore

extension Project {
    mutating func rememberFolderBookmark(_ bookmark: Data, path: String) {
        if folderBookmarks == nil { folderBookmarks = [:] }
        folderBookmarks?[path] = bookmark
    }
}

@MainActor final class ProjectFolderAccess {
    private var active: [String: URL] = [:]

    func authorize(_ chosen: URL) throws -> Data? {
        #if MARIKA_APP_STORE
        let bookmark = try chosen.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        var stale = false
        _ = try resolve(bookmark, stale: &stale)
        return bookmark
        #else
        return nil
        #endif
    }

    private func resolve(_ bookmark: Data, stale: inout Bool) throws -> URL {
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        let path = FilePath.resolved(url.path)
        if active[path] == nil {
            guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
            active[path] = url
        }
        return url
    }

    func restore(_ project: inout Project) -> [String] {
        var unavailable: [String] = []
        for path in project.repositoryURLs.map(\.path) {
            do {
                guard let bookmark = project.folderBookmarks?[path] else { throw CocoaError(.fileReadNoPermission) }
                var stale = false
                let url = try resolve(bookmark, stale: &stale)
                let resolved = FilePath.resolved(url.path)
                if stale || resolved != path {
                    let updated = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                    project.folderBookmarks?[path] = nil
                    project.rememberFolderBookmark(updated, path: resolved)
                    if project.path == path { project.path = resolved }
                    project.repositoryPaths = project.repositoryPaths?.map { $0 == path ? resolved : $0 }
                    if project.selectedRepositoryPath == path { project.selectedRepositoryPath = resolved }
                    if let layout = project.repositoryLayouts?.removeValue(forKey: path) { project.repositoryLayouts?[resolved] = layout }
                }
            } catch { unavailable.append(path) }
        }
        return unavailable
    }

    func releaseUnused(in projects: [Project]) {
        let used = Set(projects.flatMap { $0.repositoryURLs.map { FilePath.resolved($0.path) } })
        for path in active.keys.filter({ !used.contains($0) }) {
            active.removeValue(forKey: path)?.stopAccessingSecurityScopedResource()
        }
    }
}
