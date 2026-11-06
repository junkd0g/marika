import MarikaCore
import SwiftUI

struct FileBreadcrumbs: View {
    @Bindable var editor: CodeWorkspace
    var document: CodeDocument

    var body: some View {
        let components = document.path.split(separator: "/").map(String.init)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                crumb(editor.root.lastPathComponent, path: "", symbol: "folder", root: true)
                ForEach(Array(components.enumerated()), id: \.offset) { index, name in
                    chevron
                    crumb(name, path: components.prefix(index == components.count - 1 ? index : index + 1).joined(separator: "/"),
                          symbol: index == components.count - 1 ? FileVisuals.symbol(document.path) : nil)
                }
            }.fixedSize()
            HStack(spacing: 5) {
                BreadcrumbButton(editor: editor, title: "", path: "", symbol: "folder")
                chevron
                BreadcrumbButton(editor: editor, title: document.name,
                                 path: components.dropLast().joined(separator: "/"), symbol: FileVisuals.symbol(document.path))
            }
        }
        .font(.system(size: 11)).help(document.path)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var chevron: some View {
        Image(systemName: "chevron.right").font(.system(size: 7, weight: .semibold)).foregroundStyle(.tertiary)
    }
    private func crumb(_ title: String, path: String, symbol: String?, root: Bool = false) -> some View {
        BreadcrumbButton(editor: editor, title: title, path: path, symbol: symbol)
            .foregroundStyle(root ? .secondary : .primary)
    }
}

private struct BreadcrumbButton: View {
    @Bindable var editor: CodeWorkspace
    var title: String
    var path: String
    var symbol: String?
    @State private var showsFiles = false

    var body: some View {
        Button { showsFiles = true } label: {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
                if !title.isEmpty { Text(title).lineLimit(1).truncationMode(.middle) }
            }.padding(.horizontal, 4).frame(height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if DEBUG
        .background(DebugViewMarker(name: "editor-breadcrumb-" + title))
        #endif
        .accessibilityLabel("Browse \(title.isEmpty ? editor.root.lastPathComponent : title)")
        .popover(isPresented: $showsFiles, arrowEdge: .bottom) {
            BreadcrumbFiles(editor: editor, initialPath: path) { showsFiles = false }
        }
    }
}

private struct BreadcrumbFiles: View {
    @Bindable var editor: CodeWorkspace
    var initialPath: String
    var dismiss: () -> Void
    @State private var path: String
    @State private var query = ""

    init(editor: CodeWorkspace, initialPath: String, dismiss: @escaping () -> Void) {
        self.editor = editor; self.initialPath = initialPath; self.dismiss = dismiss
        _path = State(initialValue: initialPath)
    }
    private var entries: [ProjectFileEntry] {
        (editor.directories[path] ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Button {
                    path = path.split(separator: "/").dropLast().joined(separator: "/"); query = ""
                } label: { Image(systemName: "chevron.left") }
                .disabled(path.isEmpty).accessibilityLabel("Enclosing folder")
                Text(path.isEmpty ? editor.root.lastPathComponent : (path as NSString).lastPathComponent)
                    .fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Button {
                    Task { await editor.revealDirectory(path); dismiss() }
                } label: { Image(systemName: "sidebar.left") }
                .help("Show folder in file list").accessibilityLabel("Show folder in file list")
            }.buttonStyle(.plain).font(.system(size: 12)).padding(12)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter this folder…", text: $query).textFieldStyle(.plain)
            }.font(.system(size: 12)).padding(8).background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 10).padding(.bottom, 8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(entries) { entry in
                        Button {
                            if entry.isDirectory { path = entry.path; query = "" }
                            else { Task { await editor.open(entry.path); dismiss() } }
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: entry.isDirectory ? "folder" : FileVisuals.symbol(entry.path))
                                    .foregroundStyle(.secondary).frame(width: 16)
                                Text(entry.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if entry.isDirectory { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary) }
                                else if entry.path == editor.selectedDocument?.path { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }.font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        #if DEBUG
                        .background(DebugViewMarker(name: "editor-breadcrumb-entry-" + entry.path))
                        #endif
                    }
                    if entries.isEmpty {
                        Text(editor.loadingDirectories.contains(path) ? "Loading files…" : query.isEmpty ? "This folder is empty" : "No matching files")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(20)
                    }
                }.padding(5)
            }
        }.frame(width: 310, height: 320).background(Theme.panel).foregroundStyle(.primary)
        .task(id: path) { await editor.loadDirectory(path) }
        #if DEBUG
        .background(DebugViewMarker(name: "editor-breadcrumb-panel"))
        #endif
    }
}
