import SwiftUI
import MarikaCore

struct ProjectAPIView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var selection = ""
    @State private var filter = ""
    @State private var base = ""
    @State private var other = ""
    @State private var path = ""
    @State private var method = "GET"
    @State private var headers = ""
    @State private var bodyText = ""
    @State private var variables = "{}"
    @State private var response = ""
    @State private var comparison = ""
    @State private var difference = ""
    @State private var sending = false
    @State private var section = "Parameters"
    @State private var showCompose = false
    private var entries: [APIEndpoint] { project.apiCollection?.endpoints ?? [] }
    private var entry: APIEndpoint? { entries.first { $0.id == selection } }
    private var workspace: APIWorkspace? { model.apiWorkspaces[project.id] }
    private var agent: SessionController? { project.apiAgentID.flatMap { model.controllers[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("API playground").font(.title2.bold())
                Spacer()
                if let id = project.apiAgentID { Button { model.openAgentChat(id) } label: { Image(systemName: "bubble.left") }.help("Open collection agent") }
                Button("Generate collection", systemImage: "sparkles") {
                    Task { await workspace?.generate(project, model: model) }
                }.disabled(workspace == nil || workspace?.generating == true || agent?.isBusy == true)
            }
            if let agent, agent.pendingApproval != nil {
                Button("Review agent request") { model.openAgentChat(agent.id) }
            } else if agent?.isBusy == true { Label(agent?.activity ?? "Reading project routes…", systemImage: "magnifyingglass") }
            if let error = workspace?.generatingError { Text(error).foregroundStyle(.red) }
            if let plan = project.apiCollection {
                DisclosureGroup("Project environment", isExpanded: $showCompose) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let note = plan.startupNote { Text(note).foregroundStyle(.secondary) }
                        if !(plan.composeFiles ?? []).isEmpty {
                            Text((["docker"] + plan.composeArguments(projectID: project.id) + ["up","--build","-d"]).joined(separator: " ")).font(.caption.monospaced()).textSelection(.enabled)
                            HStack {
                                composeButton("Start project", ["up","--build","-d"])
                                composeButton("Status", ["ps","--all"])
                                composeButton("Logs", ["logs","--tail","40","--no-color"])
                                composeButton("Stop", ["stop"])
                            }.disabled(workspace?.busy == true)
                        }
                        if let log = workspace?.log, !log.isEmpty {
                            ScrollView { Text(log).font(.caption.monospaced()).textSelection(.enabled) }.frame(maxHeight: 105)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if entries.isEmpty {
                ContentUnavailableView("No requests yet", systemImage: "network", description: Text("Generate a collection from this project’s routes and handlers."))
            } else {
                GeometryReader { geometry in
                    let compact = geometry.size.width < 640
                    let layout = compact ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout(alignment: .top))
                    layout {
                        VStack(alignment: .leading) {
                            TextField("Filter requests", text: $filter).textFieldStyle(.roundedBorder)
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 3) {
                                    ForEach(entries.filter { filter.isEmpty || ($0.id + $0.name).localizedCaseInsensitiveContains(filter) }) { endpoint in
                                        Button { choose(endpoint) } label: {
                                            HStack {
                                                Text(endpoint.method).font(.caption.bold()).foregroundStyle(endpoint.method == "GET" ? Color.green : Color.accentColor)
                                                Text(endpoint.method == "GRAPHQL" ? endpoint.name : endpoint.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                                Spacer(minLength: 0)
                                            }.padding(5).background(selection == endpoint.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
                                        }.buttonStyle(.plain).help(endpoint.id)
                                    }
                                }
                            }
                        }.frame(width: compact ? nil : 205, height: compact ? 90 : nil).disabled(sending)
                        Divider()
                        if let entry { requestDetail(entry) }
                    }
                }
            }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            if workspace == nil { model.apiWorkspaces[project.id] = APIWorkspace() }
            if let id = project.apiAgentID { await model.open(id) }
        }
        .onChange(of: entries.map(\.id), initial: true) {
            if !entries.contains(where: { $0.id == selection }), let first = entries.first { choose(first) }
        }
    }

    private func requestDetail(_ entry: APIEndpoint) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(entry.name).font(.headline)
                Spacer()
                Button("Source") { model.openLocation(path: entry.source, line: entry.line ?? 1, root: project.url) }
            }
            TextField(entry.method == "GRPC" ? "grpc://host:port or grpcs://host:port" : "Base URL", text: $base).textFieldStyle(.roundedBorder)
            HStack {
                if APICollection.methods.contains(entry.method) {
                Picker("Method", selection: $method) { ForEach(APICollection.methods, id: \.self) { Text($0) } }.labelsHidden().fixedSize()
                } else { Text(entry.method).font(.caption.bold()) }
                TextField(entry.method == "GRPC" ? "package.Service/Method" : "/path?query=value", text: $path).textFieldStyle(.roundedBorder)
                Button("Send") { Task { await send(compare: false) } }.buttonStyle(.borderedProminent).disabled(sending)
                    #if DEBUG
                    .background(DebugViewMarker(name: "api-send"))
                    #endif
            }
            Picker("Request", selection: $section) {
                ForEach(sections(entry), id: \.self) { Text($0) }
            }.pickerStyle(.segmented).labelsHidden()
            switch section {
            case "Variables": TextEditor(text: $variables).font(.body.monospaced()).frame(height: 90)
            case "Headers", "Metadata": TextEditor(text: $headers).font(.body.monospaced()).frame(height: 65).help("One Name: value header per line")
            case "Body", "Operation", "Message": TextEditor(text: $bodyText).font(.body.monospaced()).frame(height: 85)
            case "Compare":
                HStack {
                    TextField("Second base URL", text: $other).textFieldStyle(.roundedBorder)
                    Button("Send to both") { Task { await send(compare: true) } }.disabled(sending || other.isEmpty)
                }
            default:
                TextField("Query string (e.g. page=1&limit=20)", text: Binding(get: {
                    path.components(separatedBy: "?").dropFirst().joined(separator: "?")
                }, set: { value in
                    path = (path.components(separatedBy: "?").first ?? "/") + (value.isEmpty ? "" : "?" + value)
                })).textFieldStyle(.roundedBorder)
                if let note = entry.note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            Button("Save request") {
                var saved = entry
                saved.method = method; saved.path = path; saved.body = bodyText; saved.target = base
                if method == "GRAPHQL" { saved.variables = variables }
                do { saved.headers = try APICollection.parseHeaders(headers) }
                catch { response = error.localizedDescription; return }
                model.updateProject(project.id) { current in
                    var drafts = current.apiDrafts ?? [:]; drafts[entry.id] = saved; current.apiDrafts = drafts
                }
            }
            Divider()
            Text("Response").font(.headline)
            if !difference.isEmpty { Text(difference).font(.caption).textSelection(.enabled) }
            if sending { ProgressView().controlSize(.small) }
            HStack(alignment: .top) {
                output(response)
                    #if DEBUG
                    .background(DebugViewMarker(name: response.contains("HTTP 200") || response.contains("gRPC OK") ? "api-response-ok" : "api-response"))
                    #endif
                if !comparison.isEmpty { Divider(); output(comparison) }
            }
        }
    }

    private func choose(_ item: APIEndpoint) {
        let saved = project.apiDrafts?[item.id] ?? item
        selection = item.id; method = saved.method; path = saved.path
        base = saved.target ?? project.apiCollection?.baseURL ?? ""
        variables = saved.variables ?? "{}"
        section = sections(item)[0]
        headers = (saved.headers ?? [:]).sorted { $0.key < $1.key }.map { $0.key + ": " + $0.value }.joined(separator: "\n")
        bodyText = saved.body ?? ""; response = ""; comparison = ""; difference = ""
    }
    private func sections(_ entry: APIEndpoint) -> [String] {
        switch entry.method {
        case "GRPC": ["Message","Metadata","Compare"]
        case "GRAPHQL": ["Operation","Variables","Headers","Compare"]
        default: ["Parameters","Headers","Body","Compare"]
        }
    }
    private func output(_ text: String) -> some View {
        ScrollView { Text(text).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
    }
    private func composeButton(_ title: String, _ arguments: [String]) -> some View {
        Button(title) { Task { await workspace?.compose(arguments, project: project, environment: model.gitEnvironment) } }
    }
    private func send(compare: Bool) async {
        guard !sending else { return }
        sending = true; comparison = ""; difference = ""
        defer { sending = false }
        let targets = compare ? [base, other] : [base]
        guard var draft = entry else { return }
        draft.method = method; draft.path = path; draft.body = bodyText; draft.variables = variables
        let fields = headers
        for (index, target) in targets.enumerated() {
            let result: String
            do { result = try await APICollection.execute(draft, base: target, headers: fields, root: project.url, environment: model.gitEnvironment) }
            catch { result = error.localizedDescription }
            if index == 0 { response = target + "\n" + result } else { comparison = target + "\n" + result }
        }
        if compare { difference = APICollection.differences(response, comparison) }
    }
}
