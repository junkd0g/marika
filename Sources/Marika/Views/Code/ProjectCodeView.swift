import AppKit
import MarikaCore
import SwiftUI

struct ProjectCodeView: View {
    @Environment(AppModel.self) private var model
    @Bindable var editor: CodeWorkspace
    var changeCount: Int
    var isVisible: Bool
    var isCompact = false
    var ide: IDEWorkspace?
    @State private var pendingAction: DocumentAction?
    @State private var navigatorDragStart: Double?
    @State private var settings = EditorSettings.shared
    @State private var showsSettings = false
    @State private var showsRename = false
    @State private var hoveredTab: UUID?

    private enum DocumentAction {
        case close(CodeDocument), reload(CodeDocument), overwrite(CodeDocument)

        var document: CodeDocument {
            switch self { case .close(let doc), .reload(let doc), .overwrite(let doc): doc }
        }

        var title: String {
            switch self {
            case .close: "Save changes before closing?"
            case .reload: "Reload the file from disk?"
            case .overwrite: "Replace the changes on disk?"
            }
        }
    }

    private var agentReview: AgentReviewWorkspace? {
        guard let id = model.selectedProject?.id, let review = model.agentReviews[id], review.isOpen else { return nil }
        return review
    }
    var body: some View {
        ZStack {
            editorBody.opacity(agentReview == nil ? 1 : 0).allowsHitTesting(agentReview == nil).accessibilityHidden(agentReview != nil)
            if let agentReview { AgentInlineReviewView(review: agentReview) }
        }
    }

    private var editorBody: some View {
        HStack(spacing: 0) {
            if editor.showsNavigator && !isCompact {
                FileNavigator(editor: editor).frame(width: editor.navigatorWidth)
                Rectangle().fill(Theme.hairline).frame(width: 1)
                    .overlay {
                        Color.clear.frame(width: 7).contentShape(Rectangle())
                            .gesture(DragGesture().onChanged { value in
                                if navigatorDragStart == nil { navigatorDragStart = editor.navigatorWidth }
                                editor.navigatorWidth = min(280, max(170, (navigatorDragStart ?? 220) + value.translation.width))
                            }.onEnded { _ in navigatorDragStart = nil })
                    }
            }
            VStack(spacing: 0) {
                fileTabs
                editorToolbar
                Divider()
                if let error = editor.errorMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.attention)
                        Text(error).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button { editor.errorMessage = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("Dismiss editor error")
                    }
                    .padding(12)
                    .background(Theme.attention.opacity(0.08))
                }
                if let document = editor.selectedDocument {
                    if document.changedOnDisk { conflictBanner(document) }
                    // Keep each text view alive while switching files, preserving its undo stack
                    // and scroll position. Documents also survive switching project tabs.
                    ZStack {
                        ForEach(editor.documents.filter(\.isEditable)) { doc in
                            CodeTextView(document: doc, isActive: isVisible && agentReview == nil && doc.id == editor.selectedDocumentID,
                                         findRequest: editor.findRequest, focusRequest: editor.editorFocusRequest,
                                         shouldFocus: editor.focusEditorOnSelection,
                                         style: settings.style,
                                         onEditorAction: performEditorAction,
                                         ide: ide,
                                         diagnostics: ide?.diagnostics[doc.path] ?? [],
                                         breakpoints: ide?.breakpoints[doc.path] ?? [],
                                         coverage: ide?.coverage.first(where: { $0.key.hasSuffix(doc.path) })?.value ?? [:],
                                         toggleBreakpoint: { line in
                                             guard let ide else { return }
                                             if ide.breakpoints[doc.path, default: []].contains(line) { ide.breakpoints[doc.path]?.remove(line) }
                                             else { ide.breakpoints[doc.path, default: []].insert(line) }
                                         },
                                         automaticCompletions: model.selectedProject?.tools?.completionsEnabled == true,
                                         requestCompletion: { text, offset in
                                             guard let project = model.selectedProject else { return "" }
                                             return try await model.completeCode(project: project, path: doc.path, text: text, offset: offset)
                                         })
                                .opacity(doc.id == editor.selectedDocumentID ? 1 : 0)
                                .allowsHitTesting(doc.id == editor.selectedDocumentID)
                                .accessibilityHidden(doc.id != editor.selectedDocumentID)
                        }
                        if let preview = document.preview {
                            if let error = document.previewError {
                                ContentUnavailableView("Couldn't preview this file", systemImage: "doc.badge.ellipsis",
                                                       description: Text(error))
                            } else if isVisible {
                                FilePreviewView(snapshot: preview).id(document.id)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    statusBar(document)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 32, weight: .light)).foregroundStyle(Color.accentColor)
                        Text(editor.isOpening ? "Opening file…" : "Open a file")
                            .font(.system(size: 20, weight: .semibold))
                        Text("Open code, images, PDFs, and other files from the list on the left.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                        Button("Open File…  ⌘P") { editor.showsQuickOpen = true }
                            .buttonStyle(.borderedProminent).padding(.vertical, 4)
                        Text("⌘S to save  ·  ⌘F to find  ·  ⇧⌘E for files")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let ide, ide.showsPanel { Divider(); IDEDrawer(ide: ide) }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.canvas)
        .sheet(isPresented: $editor.showsQuickOpen, onDismiss: { editor.focusEditor() }) {
            QuickOpenView(editor: editor)
        }
        .task(id: changeCount) { await editor.refresh() }
        .task(id: (editor.selectedDocument?.id.uuidString ?? "") + String(editor.selectedDocument?.revision ?? 0) + String(isVisible)) {
            guard isVisible, agentReview == nil, let document = editor.selectedDocument else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await ide?.synchronize(document)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await editor.refresh() }
        }
        .alert(pendingAction?.title ?? "", isPresented: Binding(
            get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), presenting: pendingAction
        ) { action in
            switch action {
            case .close(let document):
                Button("Save") {
                    Task {
                        if await editor.save(document), !document.isModified { editor.close(document) }
                    }
                }
                Button("Discard Changes", role: .destructive) { editor.close(document) }
            case .reload(let document):
                Button("Reload", role: .destructive) { Task { await editor.reload(document) } }
            case .overwrite(let document):
                Button("Overwrite File", role: .destructive) { Task { await editor.save(document, overwrite: true) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text("\(action.document.path)\n\n" + {
                switch action {
                case .close: "Your unsaved edits will be lost if you discard them."
                case .reload: "Your unsaved edits will be replaced with the current file on disk."
                case .overwrite: "The current file on disk will be replaced with the text in this editor."
                }
            }())
        }
    }

    private var fileTabs: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 3) {
                        ForEach(editor.documents) { document in fileTab(document).id(document.id) }
                    }.padding(.horizontal, 5)
                }
                .scrollIndicators(.hidden)
                .onChange(of: editor.selectedDocumentID) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in
                    if let id = editor.selectedDocumentID { proxy.scrollTo(id, anchor: .center) }
                }
            }
            Menu {
                ForEach(editor.documents) { document in
                    Button { editor.selectDocument(document.id) } label: {
                        Label(document.path + (document.isModified ? " •" : ""),
                              systemImage: document.id == editor.selectedDocumentID ? "checkmark" : FileVisuals.symbol(document.path))
                    }
                }
            } label: { Image(systemName: "chevron.down").frame(width: 22, height: 28) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(editor.documents.isEmpty).help("Switch open files").accessibilityLabel("Switch open files")
            Button { editor.showsQuickOpen = true } label: { Image(systemName: "plus").frame(width: 24, height: 28) }
                .buttonStyle(.plain).help("Open file (⌘P)").accessibilityLabel("Open file")
        }
        .font(.system(size: 10.5)).foregroundStyle(.secondary)
        .padding(.trailing, 7).frame(height: 34)
        .background(Theme.chrome.opacity(0.55))
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
        #if DEBUG
        .background(DebugViewMarker(name: "editor-file-tabs"))
        #endif
    }

    private var editorToolbar: some View {
        HStack(spacing: 5) {
            toolbarButton("sidebar.left", help: "Toggle file list (⌘\\)") {
                if isCompact { editor.showsQuickOpen = true } else { editor.showsNavigator.toggle() }
            }
            if !isCompact {
                toolbarButton("chevron.left", help: "Previous visited file (⌘[)") { editor.goBack() }.disabled(!editor.canGoBack)
                toolbarButton("chevron.right", help: "Next visited file (⌘])") { editor.goForward() }.disabled(!editor.canGoForward)
                toolbarDivider
            }
            if let document = editor.selectedDocument {
                FileBreadcrumbs(editor: editor, document: document)
            } else {
                Text("Workspace").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if let document = editor.selectedDocument, document.isEditable {
                toolbarButton(document.completionIsLoading ? "ellipsis" : "sparkles", help: "Suggest code (Control-Space)") {
                    editor.focusEditor(); document.completionRequest += 1
                }
                toolbarButton("magnifyingglass", help: "Find in file (⌘F)") { editor.findRequest += 1 }
                if let ide, !isCompact {
                    toolbarDivider
                    toolbarButton("exclamationmark.bubble", help: "Problems: \(ide.problemCount)", active: ide.showsPanel && ide.panel == "Problems") { togglePanel("Problems", ide: ide) }
                        .overlay(alignment: .topTrailing) {
                            if ide.problemCount > 0 { Circle().fill(Theme.attention).frame(width: 5, height: 5).padding(3) }
                        }
                    toolbarButton("checkmark.diamond", help: "Tests", active: ide.showsPanel && ide.panel == "Tests") { togglePanel("Tests", ide: ide) }
                    toolbarButton("ladybug", help: "Debug", active: ide.showsPanel && ide.panel == "Debug") { togglePanel("Debug", ide: ide) }
                }
                toolbarButton(document.isSaving ? "ellipsis" : "square.and.arrow.down", help: "Save file (⌘S)", active: document.isModified) {
                    Task { await editor.save(document) }
                }.disabled(!document.isModified || document.isSaving || document.changedOnDisk)
            }
            toolbarDivider
            toolbarButton("slider.horizontal.3", help: "Editor appearance and indentation", active: showsSettings) { showsSettings.toggle() }
                .accessibilityLabel("Editor settings")
                #if DEBUG
                .background(DebugViewMarker(name: "editor-settings-button"))
                #endif
                .popover(isPresented: $showsSettings, arrowEdge: .bottom) { EditorSettingsView(settings: settings, compact: true) }
            Menu {
                if let document = editor.selectedDocument {
                    if document.isEditable, ide != nil {
                        EditorCommands(action: performEditorAction)
                        Divider()
                    }
                    Button("Copy Relative Path") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(document.path, forType: .string)
                    }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([editor.root.appendingPathComponent(document.path)]) }
                    if !document.isEditable { Button("Reload Preview") { Task { await editor.reload(document) } } }
                    Divider()
                }
                if let ide {
                    Button("Show Problems") { togglePanel("Problems", ide: ide) }
                    Button("Show Tests") { togglePanel("Tests", ide: ide) }
                    Button("Show Debugger") { togglePanel("Debug", ide: ide) }
                    Divider()
                }
                if let project = model.selectedProject {
                    let agents = model.sessions(in: project).filter { $0.agentTask?.workspace != nil && $0.agentTask?.workspace?.status != .discarded }
                    if !agents.isEmpty {
                        Menu("Review Agent Changes") {
                            ForEach(agents) { agent in
                                Button(agent.title) { Task { await model.openAgentReview(agent.id) } }
                            }
                        }
                        Divider()
                    }
                }
                Button("Save All Files") { Task { for document in editor.modifiedDocuments { _ = await editor.save(document) } } }
                    .disabled(editor.modifiedDocuments.isEmpty)
                Button("Editor Settings…") { showsSettings = true }
            } label: { Image(systemName: "ellipsis").frame(width: 25, height: 26) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Editor actions").accessibilityLabel("Editor actions")
            .popover(isPresented: $showsRename, arrowEdge: .bottom) {
                if let ide { RenameSymbolView(ide: ide) { showsRename = false } }
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 8).frame(height: 34)
        .background(Theme.canvas)
        #if DEBUG
        .background(DebugViewMarker(name: "editor-toolbar"))
        #endif
    }

    private var toolbarDivider: some View { Rectangle().fill(Theme.hairline).frame(width: 1, height: 15).padding(.horizontal, 2) }

    private func toolbarButton(_ symbol: String, help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 25, height: 26).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(active ? Color.accentColor : .secondary)
            .background(active ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .help(help).accessibilityLabel(help)
    }

    private func togglePanel(_ panel: String, ide: IDEWorkspace) {
        let close = ide.showsPanel && ide.panel == panel
        ide.panel = panel; ide.showsPanel = !close
    }

    private func performEditorAction(_ action: String) {
        guard let ide else { return }
        if let snippet = EditorSnippet(rawValue: action) { ide.insertSnippet(settings.indentSnippet(snippet.text)) }
        else if ["Definition", "Peek Definition", "References"].contains(action), let document = editor.selectedDocument {
            document.navigationAction = action; document.navigationRequest += 1
        }
        else if action == "Rename" { ide.renameText = ""; showsRename = true }
        else { ide.perform(action) }
    }

    private func fileTab(_ document: CodeDocument) -> some View {
        HStack(spacing: 5) {
            Button { editor.selectDocument(document.id) } label: {
                HStack(spacing: 6) {
                    Image(systemName: FileVisuals.symbol(document.path)).foregroundStyle(.secondary)
                    Text(tabTitle(document)).font(.system(size: 11.5, weight: document.id == editor.selectedDocumentID ? .medium : .regular)).lineLimit(1)
                        .truncationMode(.middle).frame(maxWidth: 180)
                    if document.isModified { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                }
                .frame(height: 28)
            }
            .buttonStyle(.plain).help(document.path)
            Button {
                if document.isModified { pendingAction = .close(document) } else { editor.close(document) }
            } label: {
                Image(systemName: "xmark").font(.system(size: 9)).frame(width: 16, height: 20)
            }
            .buttonStyle(.plain).disabled(document.isSaving)
            .opacity(document.id == editor.selectedDocumentID || hoveredTab == document.id ? 1 : 0)
            .accessibilityLabel("Close \(document.name)")
        }
        .padding(.horizontal, 9).frame(height: 28)
        .foregroundStyle(document.id == editor.selectedDocumentID ? .primary : .secondary)
        .background(document.id == editor.selectedDocumentID ? Theme.canvas : hoveredTab == document.id ? Theme.surface.opacity(0.65) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .onHover { hoveredTab = $0 ? document.id : nil }
        .contextMenu {
            if document.isEditable, ide != nil {
                EditorCommands { action in editor.selectDocument(document.id); performEditorAction(action) }
                Divider()
            }
            Button("Copy Relative Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(document.path, forType: .string)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([editor.root.appendingPathComponent(document.path)])
            }
            Divider()
            Button("Close Tab") {
                if document.isModified { pendingAction = .close(document) } else { editor.close(document) }
            }
            .disabled(document.isSaving)
        }
    }

    private func tabTitle(_ document: CodeDocument) -> String {
        guard editor.documents.contains(where: { $0.id != document.id && $0.name == document.name }) else { return document.name }
        let parent = (document.path as NSString).deletingLastPathComponent
        return document.name + " · " + (parent.isEmpty ? "Project root" : parent)
    }

    private func conflictBanner(_ document: CodeDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(document.isRecoveredDraft ? "Recovered a saved draft. The original file could not be opened." : "This file changed on disk. Your edits are preserved.", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Reload from Disk") {
                    if document.isModified { pendingAction = .reload(document) }
                    else { Task { await editor.reload(document) } }
                }
                Button("Overwrite…") { pendingAction = .overwrite(document) }
                Button("Save Copy…") {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = document.name
                    panel.prompt = "Save Copy"
                    if panel.runModal() == .OK, let destination = panel.url {
                        Task { await editor.saveCopy(document, to: destination) }
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.attention.opacity(0.1))
    }

    private func statusBar(_ document: CodeDocument) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                if let preview = document.preview {
                    Text("Preview")
                    Spacer(minLength: 0)
                    Text(preview.typeName)
                    Text(ByteCountFormatter.string(fromByteCount: preview.byteCount, countStyle: .file))
                } else {
                    if let runtime = ide?.context.runtime { Text(runtime.kind == .ssh ? "SSH" : "Container").help(runtime.target) }
                    Text(document.isSaving ? "Saving…" : document.isModified ? "Modified" : "Saved")
                    Spacer(minLength: 0)
                    Text("Ln \(document.line), Col \(document.column)").monospacedDigit()
                    Button(settings.usesTabs ? "Tabs: \(settings.tabWidth)" : "Spaces: \(settings.tabWidth)") { showsSettings = true }
                        .buttonStyle(.plain).help("Editor indentation settings")
                    Text(document.snapshot?.encoding == .utf16 ? "UTF-16" : "UTF-8")
                    Text(document.text.contains("\r\n") ? "CRLF" : "LF")
                }
            }
            .font(.system(size: 10.5)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).frame(height: 25)
        }
    }
}
