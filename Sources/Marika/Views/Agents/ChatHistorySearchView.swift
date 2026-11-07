import MarikaCore
import SwiftUI

struct ChatHistorySearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var projectID: UUID?
    @State private var results = ChatHistoryResults()
    @State private var searching = false
    @State private var opening = false
    @State private var selection: String?
    @State private var error: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "text.magnifyingglass").foregroundStyle(.secondary)
                TextField("Search all conversations…", text: $query)
                    .font(.system(size: 16)).textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityLabel("Search chat history")
                    .onSubmit(openSelected)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                if searching || opening { ProgressView().controlSize(.small) }
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Close chat history search")
            }.padding(18)
            HStack {
                Picker("Search in", selection: $projectID) {
                    Text("All projects").tag(nil as UUID?)
                    ForEach(model.workspace.projects) { project in Text(project.name).tag(Optional(project.id)) }
                }.frame(maxWidth: 280)
                Spacer()
                Text("Search stays on this Mac").font(.system(size: 11)).foregroundStyle(.secondary)
            }.controlSize(.small).padding(.horizontal, 18).padding(.bottom, 12)
            Divider()
            List(results.matches, selection: $selection) { match in
                Button { open(match) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(match.projectName).fontWeight(.semibold)
                            Text("· " + match.sessionTitle).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(match.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10))
                        }.font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(match.snippet).font(.system(size: 13)).lineLimit(3).multilineTextAlignment(.leading)
                        Text(match.speaker == .user ? "You" : match.agent.shortName)
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).tag(match.id)
                .accessibilityLabel("\(match.projectName), \(match.sessionTitle), \(match.snippet)")
                #if DEBUG
                    .background(DebugViewMarker(name: "chat-history-result-" + match.itemID))
                #endif
            }
            .listStyle(.plain).disabled(opening)
            .onKeyPress(.return) { openSelected(); return .handled }
            .overlay {
                if results.matches.isEmpty {
                    ContentUnavailableView(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Search your conversations" : searching ? "Searching…" : "No matching messages",
                        systemImage: "text.magnifyingglass", description: Text("Find messages from you, Codex, and Claude across your projects."))
                }
            }
            Divider()
            HStack {
                Text(results.totalMatches > results.matches.count
                    ? "Showing \(results.matches.count) of \(results.totalMatches) messages · refine your search"
                    : "\(results.totalMatches) matching messages")
                Spacer()
                Text("↑↓ select · Return open · Esc close")
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.attention)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 12)
            } else if results.unreadableConversations > 0 {
                Text("\(results.unreadableConversations) conversations couldn't be read. Other results are shown.")
                    .font(.system(size: 11)).foregroundStyle(Theme.attention).padding(.bottom, 12)
            }
        }
        .frame(width: 720, height: 540).background(Theme.canvas)
        .onAppear { searchFocused = true }
        .onExitCommand { dismiss() }
        .task(id: query + "|" + (projectID?.uuidString ?? "all")) {
            results = ChatHistoryResults(); selection = nil; error = nil
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { searching = false; return }
            searching = true
            do {
                try await Task.sleep(for: .milliseconds(220))
                let found = try await model.searchChatHistory(query, projectID: projectID)
                try Task.checkCancellation()
                results = found; selection = found.matches.first?.id; searching = false
            } catch is CancellationError {} catch {
                if !Task.isCancelled { self.error = error.localizedDescription; searching = false }
            }
        }
        #if DEBUG
            .background(DebugViewMarker(name: "chat-history-search"))
        #endif
    }

    private func move(_ offset: Int) {
        guard !results.matches.isEmpty else { return }
        let index = results.matches.firstIndex { $0.id == selection } ?? 0
        selection = results.matches[max(0, min(results.matches.count - 1, index + offset))].id
    }

    private func openSelected() {
        if let match = results.matches.first(where: { $0.id == selection }) { open(match) }
    }

    private func open(_ match: ChatHistoryMatch) {
        guard !opening else { return }
        opening = true
        Task {
            do { try await model.revealChatHistoryMatch(match); dismiss() }
            catch { self.error = error.localizedDescription }
            opening = false
        }
    }
}
