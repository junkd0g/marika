import Foundation
import Observation

@MainActor
@Observable
public final class CodeDocument: Identifiable {
    public let id = UUID()
    public let path: String
    public var text: String { didSet { if text != oldValue { revision += 1 }; onChange?() } }
    public private(set) var revision = 0
    @ObservationIgnored var onChange: (() -> Void)?
    public fileprivate(set) var snapshot: TextFileSnapshot?
    public fileprivate(set) var preview: FilePreviewSnapshot?
    public fileprivate(set) var previewError: String?
    public fileprivate(set) var changedOnDisk = false
    public fileprivate(set) var isSaving = false
    public fileprivate(set) var isRecoveredDraft = false
    fileprivate var restoredBaseText: String?
    public var line = 1 { didSet { if line != oldValue { onChange?() } } }
    public var column = 1 { didSet { if column != oldValue { onChange?() } } }
    public var selectionRequest = 0
    public var selectionLength = 0
    public var completionRequest = 0
    public var navigationRequest = 0
    public var navigationAction = ""
    public var completionIsLoading = false
    public var completionMessage: String?
    public var foldedRanges: [NSRange] = []

    public var isEditable: Bool { snapshot != nil }
    public var isModified: Bool { isRecoveredDraft || (snapshot.map { text != $0.text } ?? false) }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }

    fileprivate init(snapshot: TextFileSnapshot) {
        self.snapshot = snapshot
        path = snapshot.path
        text = snapshot.text
    }

    fileprivate init(path: String, preview: FilePreviewSnapshot) {
        self.path = path
        self.preview = preview
        text = ""
    }

    fileprivate init(recovering state: EditorFileState) {
        path = state.path
        text = state.draft ?? ""
        let base = state.baseText ?? ""
        snapshot = TextFileSnapshot(path: state.path, text: base, data: Data(base.utf8), encoding: .utf8, hasUTF8BOM: false)
        restoredBaseText = state.baseText
        changedOnDisk = true
        isRecoveredDraft = true
    }
}

/// One editor per project, shared by that project's conversations.
@MainActor
@Observable
public final class CodeWorkspace {
    public let root: URL
    public private(set) var documents: [CodeDocument] = []
    public var selectedDocumentID: UUID?
    public private(set) var directories: [String: [ProjectFileEntry]] = [:]
    public var expandedDirectories: Set<String> = []
    public private(set) var loadingDirectories: Set<String> = []
    public var errorMessage: String?
    public private(set) var isOpening = false
    public var findRequest = 0
    public var showsQuickOpen = false
    public var showsNavigator = true { didSet { onStateChange?() } }
    public var navigatorWidth = 220.0 { didSet { onStateChange?() } }
    public var navigatorQuery = ""
    public var navigatorSelection: String?
    public var navigatorFocusRequest = 0
    public private(set) var editorFocusRequest = 0
    public private(set) var focusEditorOnSelection = true
    public private(set) var filePaths: [String] = []
    public private(set) var fileIndexRevision = 0
    public private(set) var isIndexing = false
    public private(set) var recentFilePaths: [String] = []
    @ObservationIgnored private var indexed = false
    @ObservationIgnored public var onSave: (() -> Void)?
    @ObservationIgnored public var onStateChange: (() -> Void)?
    @ObservationIgnored public var beforeSave: ((CodeDocument) async throws -> Void)?
    public private(set) var isRestoring = false
    @ObservationIgnored private let files: any WorkspaceFiles
    @ObservationIgnored private var openRevision = 0
    private struct Visit { var id: UUID; var line: Int; var column: Int }
    private var navigationHistory: [Visit] = []
    private var historyIndex = -1

    public init(root: URL, files: (any WorkspaceFiles)? = nil) {
        self.root = root
        self.files = files ?? ProjectFiles(root: root)
    }

    public var selectedDocument: CodeDocument? { documents.first { $0.id == selectedDocumentID } }
    public var modifiedDocuments: [CodeDocument] { documents.filter(\.isModified) }
    public var canGoBack: Bool { historyIndex > 0 }
    public var canGoForward: Bool { historyIndex + 1 < navigationHistory.count }

    public var savedFiles: [EditorFileState] {
        documents.map { EditorFileState(path: $0.path, draft: $0.isModified ? $0.text : nil,
                                       baseText: $0.isModified ? ($0.restoredBaseText ?? $0.snapshot?.text) : nil, line: $0.line, column: $0.column) }
    }

    public func restore(_ layout: ProjectLayout) async {
        isRestoring = true
        defer { isRestoring = false; onStateChange?() }
        showsNavigator = layout.showsNavigator
        navigatorWidth = layout.navigatorWidth
        for state in layout.files {
            await open(state.path, focus: false)
            // A missing, unreadable or newly binary file must not discard its saved draft.
            if state.draft != nil, documents.first(where: { $0.path == state.path })?.isEditable != true {
                if let preview = documents.first(where: { $0.path == state.path }) { close(preview) }
                let recovered = CodeDocument(recovering: state)
                recovered.onChange = { [weak self] in self?.onStateChange?() }
                documents.append(recovered)
                selectDocument(recovered.id, focus: false)
                errorMessage = nil
            }
            guard let document = documents.first(where: { $0.path == state.path }) else { continue }
            if let draft = state.draft, document.isEditable {
                document.changedOnDisk = document.isRecoveredDraft || (state.baseText != nil && state.baseText != document.snapshot?.text)
                document.restoredBaseText = state.baseText
                document.text = draft
            }
            document.line = max(1, state.line); document.column = max(1, state.column)
            document.selectionRequest += 1
        }
        if let selected = documents.first(where: { $0.path == layout.selectedFile }) { selectDocument(selected.id, focus: false) }
    }

    public func reveal(line: Int, column: Int = 1, length: Int = 0) {
        guard let document = selectedDocument else { return }
        document.line = max(1, line); document.column = max(1, column)
        document.selectionLength = max(0, length); document.selectionRequest += 1
        focusEditor()
    }

    public func previewText(_ path: String) async throws -> String {
        if let existing = documents.first(where: { $0.path == path }) { return existing.text }
        return try await files.read(path).text
    }

    public func navigate(to path: String, line: Int, column: Int = 1, length: Int = 0) async {
        saveCurrentVisit()
        let sameDocument = selectedDocument?.path == path
        await open(path)
        guard let document = selectedDocument, document.path == path else { return }
        if sameDocument, document.line != line || document.column != column {
            navigationHistory.removeSubrange((historyIndex + 1)..<navigationHistory.count)
            navigationHistory.append(Visit(id: document.id, line: line, column: column))
            historyIndex = navigationHistory.count - 1
        }
        reveal(line: line, column: column, length: length)
        saveCurrentVisit()
    }

    private func saveCurrentVisit() {
        guard navigationHistory.indices.contains(historyIndex), let document = selectedDocument,
              navigationHistory[historyIndex].id == document.id else { return }
        navigationHistory[historyIndex] = Visit(id: document.id, line: document.line, column: document.column)
    }

    public func loadDirectory(_ path: String = "", force: Bool = false) async {
        guard !loadingDirectories.contains(path), force || directories[path] == nil else { return }
        loadingDirectories.insert(path)
        defer { loadingDirectories.remove(path) }
        do { directories[path] = try await files.entries(in: path) }
        catch { errorMessage = error.localizedDescription }
    }

    public func revealDirectory(_ path: String) async {
        await loadDirectory(path)
        guard directories[path] != nil else { return }
        await loadDirectory()
        await revealParents(of: path)
        if !path.isEmpty { expandedDirectories.insert(path) }
        showsNavigator = true
        navigatorQuery = ""
        navigatorSelection = path.isEmpty ? nil : path
        navigatorFocusRequest += 1
    }

    public func open(_ path: String, focus: Bool = true) async {
        openRevision += 1
        let revision = openRevision
        if let existing = documents.first(where: { $0.path == path }) {
            selectDocument(existing.id, focus: focus)
            isOpening = false
            errorMessage = nil
            await revealParents(of: path)
            return
        }
        isOpening = true
        defer { if revision == openRevision { isOpening = false } }
        do {
            let content = try await files.open(path)
            guard revision == openRevision else { return }
            let document: CodeDocument
            switch content {
            case .text(let snapshot): document = CodeDocument(snapshot: snapshot)
            case .preview(let preview): document = CodeDocument(path: path, preview: preview)
            }
            documents.append(document)
            document.onChange = { [weak self] in self?.onStateChange?() }
            selectDocument(document.id, focus: focus)
            errorMessage = nil
            await revealParents(of: path)
        } catch {
            if revision == openRevision { errorMessage = error.localizedDescription }
        }
    }

    public func selectDocument(_ id: UUID, focus: Bool = true) {
        activateDocument(id, focus: focus, recordHistory: true)
    }

    private func activateDocument(_ id: UUID, focus: Bool, recordHistory: Bool) {
        guard let document = documents.first(where: { $0.id == id }) else { return }
        // Previewing a row with the arrow keys is still navigation, but asking the
        // already-selected editor to take focus must not add a duplicate visit.
        if recordHistory, historyIndex < 0 || navigationHistory[historyIndex].id != id {
            saveCurrentVisit()
            navigationHistory.removeSubrange((historyIndex + 1)..<navigationHistory.count)
            navigationHistory.append(Visit(id: id, line: document.line, column: document.column))
            if navigationHistory.count > 100 { navigationHistory.removeFirst() }
            historyIndex = navigationHistory.count - 1
        }
        recentFilePaths.removeAll { $0 == document.path }
        recentFilePaths.insert(document.path, at: 0)
        if recentFilePaths.count > 100 { recentFilePaths.removeLast() }
        focusEditorOnSelection = focus
        selectedDocumentID = id
        navigatorSelection = document.path
        if focus { editorFocusRequest += 1 }
        onStateChange?()
    }

    public func goBack() {
        guard canGoBack else { return }
        saveCurrentVisit()
        historyIndex -= 1
        let visit = navigationHistory[historyIndex]
        activateDocument(visit.id, focus: true, recordHistory: false)
        reveal(line: visit.line, column: visit.column)
    }

    public func goForward() {
        guard canGoForward else { return }
        saveCurrentVisit()
        historyIndex += 1
        let visit = navigationHistory[historyIndex]
        activateDocument(visit.id, focus: true, recordHistory: false)
        reveal(line: visit.line, column: visit.column)
    }

    public func selectAdjacentDocument(_ offset: Int) {
        guard !documents.isEmpty else { return }
        let current = documents.firstIndex(where: { $0.id == selectedDocumentID }) ?? 0
        selectDocument(documents[(current + offset % documents.count + documents.count) % documents.count].id)
    }

    public struct NavigatorEntry: Identifiable {
        public let entry: ProjectFileEntry
        public let depth: Int
        public var id: String { entry.path }
    }

    public var visibleEntries: [NavigatorEntry] {
        func children(_ path: String, depth: Int) -> [NavigatorEntry] {
            guard depth < 40 else { return [] }
            return (directories[path] ?? []).flatMap { entry in
                [NavigatorEntry(entry: entry, depth: depth)]
                    + (entry.isDirectory && expandedDirectories.contains(entry.path) ? children(entry.path, depth: depth + 1) : [])
            }
        }
        return children("", depth: 0)
    }

    public func toggleDirectory(_ path: String) async {
        if expandedDirectories.contains(path) { expandedDirectories.remove(path) }
        else {
            expandedDirectories.insert(path)
            await loadDirectory(path)
        }
    }

    public func loadFileIndex(force: Bool = false) async {
        guard !isIndexing, !indexed || force else { return }
        isIndexing = true
        defer { isIndexing = false }
        do {
            filePaths = try await files.filePaths(limit: 20_000)
            indexed = true
            fileIndexRevision += 1
        } catch { errorMessage = error.localizedDescription }
    }

    public func searchFiles(_ query: String) async -> [String] {
        await loadFileIndex()
        let paths = filePaths
        return await Task.detached(priority: .userInitiated) { FileSearch.matches(paths, query: query) }.value
    }

    public func focusEditor() {
        focusEditorOnSelection = true
        editorFocusRequest += 1
    }

    private func revealParents(of path: String) async {
        let components = path.split(separator: "/").dropLast()
        var parent = ""
        for component in components {
            parent = parent.isEmpty ? String(component) : parent + "/" + component
            expandedDirectories.insert(parent)
            await loadDirectory(parent)
        }
    }

    @discardableResult
    public func save(_ document: CodeDocument, overwrite: Bool = false) async -> Bool {
        guard !document.isSaving, let snapshot = document.snapshot else { return false }
        guard !document.changedOnDisk || overwrite else { errorMessage = ProjectFileError.changedOnDisk.localizedDescription; return false }
        document.isSaving = true
        defer { document.isSaving = false }
        do { try await beforeSave?(document) }
        catch { errorMessage = error.localizedDescription; return false }
        guard document.isModified || overwrite else { return true }
        let text = document.text
        do {
            document.snapshot = try await files.write(text, replacing: snapshot, overwrite: overwrite)
            document.changedOnDisk = false
            document.isRecoveredDraft = false
            document.restoredBaseText = nil
            errorMessage = nil
            onSave?()
            return true
        } catch {
            if error as? ProjectFileError == .changedOnDisk { document.changedOnDisk = true }
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func reload(_ document: CodeDocument) async {
        if document.preview != nil {
            do {
                document.preview = try await files.preview(document.path)
                document.previewError = nil
            } catch { document.previewError = error.localizedDescription }
            return
        }
        // Don't erase edits made while the disk read was in flight.
        let previous = document.text
        do {
            let snapshot = try await files.read(document.path)
            guard document.text == previous else { return }
            document.snapshot = snapshot
            document.text = snapshot.text
            document.changedOnDisk = false
            document.isRecoveredDraft = false
            document.restoredBaseText = nil
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    public func refresh() async {
        for path in Array(directories.keys) { await loadDirectory(path, force: true) }
        if directories[""] == nil { await loadDirectory() }
        if indexed { await loadFileIndex(force: true) }
        for document in documents where !document.isSaving {
            if document.preview != nil { await reload(document); continue }
            guard let previous = document.snapshot?.data else { continue }
            do {
                let updated = try await files.read(document.path)
                guard previous == document.snapshot?.data else { continue }
                if document.isModified {
                    document.changedOnDisk = document.isRecoveredDraft || (document.restoredBaseText.map { $0 != updated.text } ?? (updated.data != previous))
                } else {
                    document.snapshot = updated
                    document.text = updated.text
                    document.changedOnDisk = false
                }
            } catch { document.changedOnDisk = true }
        }
    }

    /// The destination is chosen explicitly by the user in a Save panel.
    @discardableResult
    public func saveCopy(_ document: CodeDocument, to destination: URL) async -> Bool {
        let data = Data(document.text.utf8)
        do {
            try await Task.detached { try data.write(to: destination, options: .atomic) }.value
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// The UI confirms unsaved changes before calling this.
    public func close(_ document: CodeDocument) {
        guard !document.isSaving, let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        let visitsBeforeCurrent = navigationHistory.prefix(historyIndex + 1).filter { $0.id != document.id }.count
        navigationHistory.removeAll { $0.id == document.id }
        historyIndex = visitsBeforeCurrent - 1
        documents.remove(at: index)
        onStateChange?()
        if selectedDocumentID == document.id {
            selectedDocumentID = documents.isEmpty ? nil : documents[min(index, documents.count - 1)].id
            if let selectedDocumentID { selectDocument(selectedDocumentID) }
            else { navigatorSelection = nil }
        }
    }
}
