import AppKit
import MarikaCore
import SwiftUI

struct DesignLinksEditor: View {
    let canvas: DesignCanvasModel
    let nodeID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var kind = DesignSourceLink.Kind.file
    @State private var target = ""
    @State private var line = ""
    @State private var filter = ""
    @State private var symbols: [SourceSymbol] = []
    @State private var selected: SourceSymbol?
    @State private var loadedPath: String?
    @State private var loading = false
    @State private var lookupTask: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var error: String?
    private var project: Project? { canvas.app?.project(id: canvas.projectID) }
    private var filtered: [SourceSymbol] { symbols.filter { filter.isEmpty || $0.identity.name.localizedCaseInsensitiveContains(filter) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Link code and documentation").font(.title2.weight(.semibold))
            Text("Symbol links follow declarations when their line numbers change.").foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(canvas.doc.node(nodeID)?.links ?? []) { link in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(link.displayName).lineLimit(1).truncationMode(.middle)
                                if link.kind == .symbol { Text(link.target).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Spacer()
                            Button("Open") { open(link) }
                            if link.kind == .symbol { Button("References") { open(link, references: true) } }
                            Button("Remove") { canvas.edit { $0.update([nodeID]) { $0.links?.removeAll { $0.id == link.id } } } }
                        }.font(.system(size: 12))
                    }
                }
            }.frame(maxHeight: 160)
            Divider()
            Picker("Link type", selection: $kind) {
                ForEach(DesignSourceLink.Kind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }.pickerStyle(.segmented)
            #if DEBUG
            .background(DebugViewMarker(name: "design-link-kind"))
            #endif
            if kind == .endpoint, let endpoints = project?.apiCollection?.endpoints, !endpoints.isEmpty {
                Picker("API request", selection: $target) {
                    Text("Choose an endpoint").tag("")
                    ForEach(endpoints) { Text($0.id).tag($0.id) }
                }
            } else {
                HStack {
                    TextField(kind == .documentation ? "https://…" : "Relative file path", text: $target).textFieldStyle(.roundedBorder)
                    #if DEBUG
                    .background(DebugViewMarker(name: "design-link-target"))
                    #endif
                    if kind == .file || kind == .symbol { Button("Browse…", action: browse) }
                }
            }
            if kind == .file {
                TextField("Line (optional)", text: $line).textFieldStyle(.roundedBorder).frame(width: 140)
            }
            if kind == .symbol { symbolPicker }
            if let error { Text(error).foregroundStyle(.red).font(.caption).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add link", action: add).buttonStyle(WorkspaceButtonStyle(kind: .primary))
                    .disabled(target.isEmpty || (kind == .symbol && (selected == nil || loadedPath != target)))
                #if DEBUG
                    .background(DebugViewMarker(name: "design-link-add"))
                #endif
            }
        }.padding(24).frame(width: 590)
            .onChange(of: target) { _, _ in resetLookup() }.onChange(of: kind) { _, _ in resetLookup() }
            .onDisappear { lookupTask?.cancel() }
        #if DEBUG
            .background(DebugViewMarker(name: "design-links-editor"))
        #endif
    }

    private var symbolPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(loading ? "Finding declarations…" : "Find declarations", action: lookup).disabled(loading || target.isEmpty)
                #if DEBUG
                    .background(DebugViewMarker(name: "design-find-declarations"))
                #endif
                if loading { ProgressView().controlSize(.small) }
                Spacer()
            }
            if loadedPath == target {
                TextField("Filter declarations", text: $filter).textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if filtered.isEmpty { Text("No matching declarations.").foregroundStyle(.secondary).padding(8) }
                        ForEach(filtered) { symbol in
                            Button { selected = symbol } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(symbol.identity.name).lineLimit(1).truncationMode(.middle)
                                        Text(symbol.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if selected == symbol { Image(systemName: "checkmark") }
                                }.padding(8).contentShape(Rectangle())
                                    .background(selected == symbol ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
                            }.buttonStyle(.plain)
                            #if DEBUG
                            .background(DebugViewMarker(name: "design-symbol-row"))
                            #endif
                        }
                    }
                }.frame(height: 160)
            }
        }
    }
    private func resetLookup() {
        generation = UUID(); lookupTask?.cancel(); lookupTask = nil
        symbols = []; selected = nil; loadedPath = nil; loading = false; error = nil
    }
    private func lookup() {
        guard let app = canvas.app else { return }
        resetLookup()
        let token = generation, path = target
        loading = true
        lookupTask = Task {
            do {
                let result = try await app.designSymbols(projectID: canvas.projectID, path: path)
                guard !Task.isCancelled, generation == token, target == path else { return }
                symbols = result; loadedPath = path; loading = false
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                self.error = error.localizedDescription; loading = false
            }
        }
    }
    private func add() {
        let number = line.isEmpty ? nil : Int(line)
        guard kind != .file || line.isEmpty || number != nil else { error = "Enter a positive line number."; return }
        let declaration = kind == .symbol ? selected : nil
        let link = DesignSourceLink(kind: kind, target: target.trimmingCharacters(in: .whitespacesAndNewlines),
                                    line: declaration.map { $0.position.line + 1 } ?? (kind == .file ? number : nil),
                                    symbol: declaration?.identity.name, symbolIdentity: declaration?.identity)
        guard link.isValid, kind != .symbol || declaration != nil else { error = "Choose a valid file, declaration, endpoint, or HTTP(S) URL."; return }
        guard (canvas.doc.node(nodeID)?.links?.count ?? 0) < 20 else { error = "This element already has 20 links."; return }
        canvas.edit { $0.update([nodeID]) { $0.links = ($0.links ?? []) + [link] } }
        target = ""; line = ""; filter = ""; resetLookup()
    }
    private func open(_ link: DesignSourceLink, references: Bool = false) {
        Task {
            do {
                if references { try await canvas.app?.openDesignSymbolReferences(link, projectID: canvas.projectID) }
                else { try await canvas.app?.openDesignLink(link, projectID: canvas.projectID) }
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
    private func browse() {
        guard let project else { return }
        let panel = NSOpenPanel(); panel.directoryURL = project.url; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let root = project.url.standardizedFileURL.resolvingSymlinksInPath().path
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(root + "/") else { error = "Choose a file inside this project."; return }
        target = String(path.dropFirst(root.count + 1))
    }
}
