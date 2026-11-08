import AppKit
import MarikaCore
import SwiftUI

struct ProjectKnowledgeView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var query = ""
    @State private var selection: UUID?
    @State private var editing: KnowledgeEditorDraft?
    @State private var error: String?
    @State private var importing = false
    @State private var matches: [KnowledgeMatch] = []
    private var library: ProjectKnowledge { model.project(id: project.id)?.knowledge ?? ProjectKnowledge() }
    private var selected: KnowledgeEntry? { library.entries.first { $0.id == selection } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack { heading; Spacer(); actions }
                VStack(alignment: .leading) { heading; actions }
            }
            Text("Approved documents, links and decisions are searchable by every project agent. Proposed memory changes wait for your review. Imported text is a saved snapshot.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Search documents and decisions…", text: $query).textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(Theme.attention).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !library.proposals.isEmpty {
                        DisclosureGroup("Review memory updates (\(library.proposals.count))") {
                            ForEach(library.proposals) { proposal in proposalCard(proposal) }
                        }
                    }
                    if let selected {
                        detail(selected)
                    } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if matches.isEmpty { ContentUnavailableView.search(text: query) }
                        ForEach(matches) { match in
                            VStack(alignment: .leading, spacing: 8) {
                                Button(match.title) { selection = match.entryID }.font(.headline)
                                Text(match.excerpt).font(.callout).textSelection(.enabled)
                                HStack { Text(match.citation).font(.caption.monospaced()); Spacer(); CopyButton(text: match.citation) }
                            }.padding(14).surface()
                        }
                    } else if library.entries.isEmpty {
                        ContentUnavailableView("Build project knowledge", systemImage: "books.vertical", description: Text("Import a document or add a link or decision. Agents can propose lasting updates after completing work."))
                    } else {
                        ForEach(library.entries.sorted { $0.updatedAt > $1.updatedAt }) { entry in
                            Button { selection = entry.id } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack { Text(entry.title).font(.headline); Spacer(); Text(entry.kind.rawValue.capitalized).font(.caption) }
                                    Text(String(entry.content.prefix(500))).lineLimit(2).font(.callout).foregroundStyle(.secondary)
                                    Text("Revision \(entry.revision) · " + entry.updatedAt.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).surface().contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(.vertical, 8)
            }
        }.padding(20)
        .task(id: query + library.entries.map { $0.id.uuidString + ":" + String($0.revision) }.joined()) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let snapshot = library, search = query
            let result = await Task.detached { snapshot.search(search, limit: 20) }.value
            guard !Task.isCancelled else { return }; matches = result
        }
        .onChange(of: query) { selection = nil }
        .sheet(item: $editing) { draft in
            KnowledgeEditor(draft: draft) { entry in
                try model.saveKnowledge(entry, projectID: project.id, replacing: draft.original?.id, revision: draft.original?.revision)
                selection = draft.original?.id ?? entry.id; editing = nil
            }
        }
    }
    private var heading: some View { VStack(alignment: .leading, spacing: 4) { Text("Project knowledge").font(.title3.bold()); Text("\(library.entries.count) approved · \(library.proposals.count) pending").font(.caption).foregroundStyle(.secondary) } }
    private var actions: some View {
        HStack {
            Button(importing ? "Importing…" : "Import document") {
                let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                panel.message = "Import text, Markdown, CSV, PDF, DOCX or RTF. PDF text extraction does not include OCR."
                guard panel.runModal() == .OK, let url = panel.url else { return }
                importing = true
                Task { defer { importing = false }; do { try await model.importKnowledge(url, projectID: project.id); error = nil } catch { self.error = error.localizedDescription } }
            }.disabled(importing)
            Button("Add knowledge", systemImage: "plus") { editing = KnowledgeEditorDraft() }
        }.controlSize(.small)
    }
    private func detail(_ entry: KnowledgeEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("All knowledge") { selection = nil }
                Spacer()
                Button("Edit") { editing = KnowledgeEditorDraft(original: entry) }
                Button("Remove", role: .destructive) {
                    model.updateProject(project.id) { current in
                        var library = current.knowledge ?? ProjectKnowledge()
                        library.history = Array(((library.history ?? []) + [entry]).suffix(200))
                        library.entries.removeAll { $0.id == entry.id }; current.knowledge = library
                    }
                    model.reconnectKnowledge(project.id); selection = nil
                }
            }.controlSize(.small)
            Text(entry.title).font(.title2.bold())
            Text("Revision \(entry.revision) · " + entry.updatedAt.formatted()).font(.caption).foregroundStyle(.secondary)
            if let source = entry.source {
                if entry.kind == .link, let url = URL(string: source) { Link(source, destination: url) } else { Text("Imported from " + source).font(.caption) }
            }
            Text(entry.content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(text: "[K:\(entry.id.uuidString):\(entry.revision):1]")
            let history = (library.history ?? []).filter { $0.id == entry.id }.reversed()
            if !history.isEmpty { DisclosureGroup("Previous revisions (\(history.count))") { ForEach(Array(history.enumerated()), id: \.offset) { _, old in Text("Revision \(old.revision)\n\(old.content)").font(.callout).textSelection(.enabled).padding(.vertical, 8) } } }
        }.padding(16).surface()
    }
    private func proposalCard(_ proposal: KnowledgeProposal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(proposal.entry.title).font(.headline)
            Text(proposal.reason).font(.callout).foregroundStyle(.secondary)
            if let old = library.entries.first(where: { $0.id == proposal.replacesID }) {
                Text("Current · revision \(old.revision)").font(.caption.bold())
                Text(old.content).font(.callout).textSelection(.enabled)
            }
            Text("Proposed content").font(.caption.bold())
            Text(proposal.entry.content).font(.callout).textSelection(.enabled)
            if let source = proposal.entry.source { Text(source).font(.caption).textSelection(.enabled) }
            HStack {
                Button("Approve update") { do { try model.approveKnowledge(proposal.id, projectID: project.id); error = nil } catch { self.error = error.localizedDescription } }
                Button("Reject") { model.updateProject(project.id) { $0.knowledge?.proposals.removeAll { $0.id == proposal.id } } }
                Spacer()
                if let id = proposal.entry.sessionID, model.workspace.sessions.contains(where: { $0.id == id }) { Button("Open source chat") { model.openAgentChat(id) } }
            }.controlSize(.small)
        }.padding(14).surface()
    }
}

private struct KnowledgeEditorDraft: Identifiable {
    var id = UUID()
    var original: KnowledgeEntry?
}
private struct KnowledgeEditor: View {
    @Environment(\.dismiss) private var dismiss
    let draft: KnowledgeEditorDraft
    let save: (KnowledgeEntry) throws -> Void
    @State private var title = ""
    @State private var content = ""
    @State private var source = ""
    @State private var kind: KnowledgeEntry.Kind = .decision
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.original == nil ? "Add project knowledge" : "Edit knowledge snapshot").font(.title2.bold())
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            Picker("Kind", selection: $kind) { ForEach(KnowledgeEntry.Kind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }.pickerStyle(.segmented)
            TextField(kind == .link ? "Source URL (https://…)" : "Source or provenance (optional)", text: $source).textFieldStyle(.roundedBorder)
            Text("Saved text or decision").font(.headline)
            TextEditor(text: $content).font(.body).frame(minHeight: 200).border(Theme.hairline)
            Text("Links store the text you supply. To capture current web evidence, ask a research agent to retrieve the URL and propose a knowledge item.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(Theme.attention) }
            }
            }
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Save knowledge") { do { try save(KnowledgeEntry(title: title, kind: kind, content: content, source: source.isEmpty ? nil : source, sessionID: draft.original?.sessionID)) } catch { self.error = error.localizedDescription } }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 580, height: 570)
        .onAppear { if let entry = draft.original { title = entry.title; content = entry.content; source = entry.source ?? ""; kind = entry.kind } }
    }
}
