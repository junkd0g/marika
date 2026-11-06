import MarikaCore
import SwiftUI

enum FileVisuals {
    static func symbol(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": "swift"
        case "go": "g.circle"
        case "proto": "network"
        case "graphql", "gql", "graphqls": "point.3.connected.trianglepath.dotted"
        case "js", "jsx", "ts", "tsx", "json": "curlybraces"
        case "html", "htm", "css", "scss": "chevron.left.forwardslash.chevron.right"
        case "md", "txt": "doc.text"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "tif", "tiff", "ico": "photo"
        case "pdf": "doc.richtext"
        case "mp4", "mov", "webm", "m4v": "film"
        case "mp3", "wav", "m4a", "aiff", "flac": "waveform"
        default: "doc"
        }
    }
}

struct FileNavigator: View {
    @Bindable var editor: CodeWorkspace
    @State private var matches: [String] = []
    @FocusState private var listFocused: Bool

    private var query: String { editor.navigatorQuery }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Files").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { editor.showsQuickOpen = true } label: { Image(systemName: "doc.text.magnifyingglass") }
                    .help("Go to file (⌘P)").accessibilityLabel("Go to file")
                Button { Task { await editor.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh files").accessibilityLabel("Refresh files")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).padding(12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find files…", text: $editor.navigatorQuery).textFieldStyle(.plain)
                    .accessibilityLabel("Find project files")
                if !query.isEmpty {
                    Button { editor.navigatorQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear file search")
                }
            }
            .font(.system(size: 12)).padding(8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 8).padding(.bottom, 9)
            Text(editor.root.lastPathComponent).font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 12).padding(.bottom, 9)
            Divider()
            ScrollViewReader { proxy in
                List(selection: Binding(get: { editor.navigatorSelection }, set: { value in selectInNavigator(value) })) {
                    if query.isEmpty {
                        ForEach(editor.visibleEntries) { row in
                            treeRow(row).tag(row.id).id(row.id)
                        }
                    } else {
                        ForEach(matches, id: \.self) { path in
                            Button { Task { await editor.open(path) } } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Label((path as NSString).lastPathComponent, systemImage: FileVisuals.symbol(path))
                                        .font(.system(size: 12)).lineLimit(1)
                                    Text((path as NSString).deletingLastPathComponent)
                                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 2).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).tag(path).id(path)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .focused($listFocused)
                .onChange(of: editor.selectedDocumentID) { _, _ in
                    if let path = editor.selectedDocument?.path { proxy.scrollTo(path, anchor: .center) }
                }
                .onChange(of: editor.navigatorFocusRequest) { _, _ in listFocused = true }
                .onKeyPress(.return) { activateSelection(); return .handled }
                .onKeyPress(.rightArrow) { expandSelection(); return .handled }
                .onKeyPress(.leftArrow) { collapseSelection(); return .handled }
                .overlay {
                    if query.isEmpty, editor.visibleEntries.isEmpty {
                        Text(editor.loadingDirectories.contains("") ? "Loading files…" : "This folder is empty")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else if !query.isEmpty, matches.isEmpty {
                        Text(editor.isIndexing ? "Finding files…" : "No matching files")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                if editor.isIndexing { ProgressView().controlSize(.mini) }
                Text(query.isEmpty ? "⌘P to jump to any file" : "\(matches.count) matches")
                Spacer(minLength: 0)
                Button {
                    editor.expandedDirectories.removeAll()
                } label: { Image(systemName: "rectangle.compress.vertical") }
                    .buttonStyle(.plain).help("Collapse all folders").accessibilityLabel("Collapse all folders")
            }
            .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(10)
        }
        .background(Theme.chrome.opacity(0.55))
        .task(id: query + "|" + String(editor.fileIndexRevision)) {
            guard !query.isEmpty else { return }
            let results = await editor.searchFiles(query)
            if !Task.isCancelled { matches = results }
        }
    }

    private func treeRow(_ row: CodeWorkspace.NavigatorEntry) -> some View {
        Button {
            if row.entry.isDirectory { Task { await editor.toggleDirectory(row.id) } }
            else { Task { await editor.open(row.id) } }
        } label: {
            treeRowLabel(row)
        }
        .buttonStyle(.plain).help(row.id)
    }

    private func treeRowLabel(_ row: CodeWorkspace.NavigatorEntry) -> some View {
        HStack(spacing: 6) {
            if row.entry.isDirectory {
                Image(systemName: editor.expandedDirectories.contains(row.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 10)
            } else { Color.clear.frame(width: 10, height: 1) }
            Image(systemName: row.entry.isDirectory ? "folder" : row.entry.isSymbolicLink ? "link" : FileVisuals.symbol(row.id))
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
            Text(row.entry.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if editor.documents.contains(where: { $0.path == row.id && $0.isModified }) {
                Circle().fill(Color.accentColor).frame(width: 5, height: 5)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 12)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func activateSelection() {
        guard let path = editor.navigatorSelection else { return }
        if editor.visibleEntries.first(where: { $0.id == path })?.entry.isDirectory == true {
            Task { await editor.toggleDirectory(path) }
        } else { Task { await editor.open(path) } }
    }

    private func selectInNavigator(_ path: String?) {
        editor.navigatorSelection = path
        guard let path, query.isEmpty
            ? editor.visibleEntries.first(where: { $0.id == path })?.entry.isDirectory == false : true
        else { return }
        Task {
            // Opening a file also updates the selection. Only a new navigator selection
            // should preview it without focus; never undo the focus from a file click.
            guard editor.navigatorSelection == path, editor.selectedDocument?.path != path else { return }
            await editor.open(path, focus: false)
        }
    }

    private func expandSelection() {
        guard let path = editor.navigatorSelection,
            let row = editor.visibleEntries.first(where: { $0.id == path }), row.entry.isDirectory
        else { return }
        if !editor.expandedDirectories.contains(path) { Task { await editor.toggleDirectory(path) } }
        else if let first = editor.directories[path]?.first { selectInNavigator(first.path) }
    }

    private func collapseSelection() {
        guard let path = editor.navigatorSelection else { return }
        if editor.expandedDirectories.contains(path) { editor.expandedDirectories.remove(path) }
        else {
            let parent = path.split(separator: "/").dropLast().joined(separator: "/")
            if !parent.isEmpty { editor.navigatorSelection = parent }
        }
    }
}

struct QuickOpenView: View {
    @Bindable var editor: CodeWorkspace
    @State private var query = ""
    @State private var matches: [String] = []
    @State private var selection: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.accentColor)
                TextField("Go to file…", text: $query)
                    .font(.system(size: 15)).textFieldStyle(.plain).focused($searchFocused)
                    .onSubmit(openSelected)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                if editor.isIndexing { ProgressView().controlSize(.small) }
                Button { editor.showsQuickOpen = false } label: { Text("esc").font(.system(size: 10)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
            .padding(18)
            Divider()
            ScrollViewReader { proxy in
                List(matches, id: \.self, selection: $selection) { path in
                    Button { selection = path; openSelected() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: FileVisuals.symbol(path)).foregroundStyle(.secondary).frame(width: 18)
                            Text((path as NSString).lastPathComponent).font(.system(size: 13, weight: .medium))
                            Text((path as NSString).deletingLastPathComponent)
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            if editor.documents.contains(where: { $0.path == path && $0.isModified }) {
                                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                            }
                        }
                        .padding(.vertical, 4).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).tag(path).id(path)
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .onKeyPress(.return) { openSelected(); return .handled }
                .overlay {
                    if matches.isEmpty { Text(editor.isIndexing ? "Indexing project files…" : "No matching files").foregroundStyle(.secondary) }
                }
                .onChange(of: selection) { _, path in
                    if let path { proxy.scrollTo(path) }
                }
            }
            Divider()
            HStack {
                Text("↑↓ choose  ·  Return open  ·  Esc cancel")
                Spacer()
                Text("\(editor.filePaths.count) files")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
        }
        .frame(width: 600, height: 430)
        .background(Theme.canvas)
        .onAppear { searchFocused = true }
        .onExitCommand { editor.showsQuickOpen = false }
        .task(id: query + "|" + String(editor.fileIndexRevision)) {
            var results = await editor.searchFiles(query)
            if query.isEmpty {
                let recent = editor.recentFilePaths.filter { editor.filePaths.contains($0) }
                results = recent + results.filter { !recent.contains($0) }
            }
            guard !Task.isCancelled else { return }
            matches = results
            selection = results.first
        }
    }

    private func move(_ offset: Int) {
        guard !matches.isEmpty else { return }
        let index = matches.firstIndex(of: selection ?? "") ?? 0
        selection = matches[max(0, min(matches.count - 1, index + offset))]
    }

    private func openSelected() {
        guard let path = selection ?? matches.first else { return }
        editor.showsQuickOpen = false
        Task { await editor.open(path) }
    }
}
