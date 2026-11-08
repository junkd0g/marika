import MarikaCore
import SwiftUI

struct ProjectAPIView: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        Group {
            if let workspace = model.apiWorkspaces[project.id] {
                APIPlaygroundView(project: project, workspace: workspace)
            } else { ProgressView().controlSize(.small) }
        }
        .task {
            if model.apiWorkspaces[project.id] == nil { model.apiWorkspaces[project.id] = APIWorkspace() }
            if let id = project.apiAgentID { await model.open(id) }
        }
    }
}

private struct APIPlaygroundView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @Bindable var workspace: APIWorkspace
    @State private var showEnvironment = false

    private var entries: [APIRequestItem] {
        (project.apiCollection?.endpoints ?? []).map {
            APIRequestItem(source: $0, saved: project.apiDrafts?[$0.id], draft: workspace.drafts[$0.id])
        }
    }
    private var filtered: [APIRequestItem] { entries.filter { $0.matches(workspace.filter) } }
    private var selected: APIRequestItem? { entries.first { $0.id == workspace.selectedRequestID } }
    private var agent: SessionController? { project.apiAgentID.flatMap { model.controllers[$0] } }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                if let error = workspace.generatingError { notice(error, symbol: "exclamationmark.triangle", color: .red) }
                if let agent, agent.isBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text(agent.pendingApproval == nil ? agent.activity ?? "Reading project routes…" : "Collection agent needs your approval")
                        Spacer()
                        Button(agent.pendingApproval == nil ? "Open Chat" : "Review Approval") { model.openAgentChat(agent.id) }
                    }.font(.caption).padding(12).background(Theme.panel)
                }
                environment
                Divider()
                if entries.isEmpty {
                    ContentUnavailableView {
                        Label("Explore your project's API", systemImage: "network")
                    } description: {
                        Text("Generate requests from the routes and handlers in your project, then edit, send and compare responses here.")
                    } actions: {
                        Button("Generate collection", systemImage: "sparkles") { generate() }
                            .buttonStyle(.borderedProminent).disabled(generating)
                    }
                } else if geometry.size.width >= 760 {
                    HStack(spacing: 0) {
                        requestList.frame(width: min(340, max(230, geometry.size.width * 0.2)))
                        Divider()
                        detail
                    }
                } else {
                    VStack(spacing: 0) {
                        compactNavigation
                        Divider()
                        detail
                    }
                }
            }
        }
        .background(Theme.canvas)
        .task(id: entries.map(\.id)) {
            if let selected { workspace.select(selected.source, project: project) }
            else if let first = entries.first { workspace.select(first.source, project: project) }
        }
    }

    private var generating: Bool { workspace.generating || agent?.isBusy == true }
    private func generate() { Task { await workspace.generate(project, model: model) } }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("API").font(.system(size: 21, weight: .semibold))
                Text("\(project.name) · \(entries.count) \(entries.count == 1 ? "request" : "requests")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let id = project.apiAgentID {
                Button { model.openAgentChat(id) } label: { Image(systemName: "bubble.left") }
                    .help("Open collection agent").accessibilityLabel("Open collection agent")
            }
            if !entries.isEmpty {
                Button("Regenerate", systemImage: "arrow.clockwise") { generate() }.disabled(generating)
            }
        }.padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var search: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find a request", text: $workspace.filter).textFieldStyle(.plain)
                .accessibilityLabel("Find API requests").onExitCommand { workspace.filter = "" }
            if !workspace.filter.isEmpty {
                Button { workspace.filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear request filter")
            }
        }.padding(8).background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
    }

    private var requestList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("REQUESTS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(filtered.count)").font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 16)
            search
            if filtered.isEmpty {
                ContentUnavailableView("No matching requests", systemImage: "magnifyingglass",
                                       description: Text("Try a method, name or path."))
            } else {
                List(selection: Binding(get: { workspace.selectedRequestID }, set: { id in
                    if let item = entries.first(where: { $0.id == id }) { workspace.select(item.source, project: project) }
                })) {
                    ForEach(filtered) { endpoint in
                        HStack(alignment: .top, spacing: 8) {
                            APIMethodBadge(method: endpoint.method)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(endpoint.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                Text(endpoint.path).font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            if workspace.runningRequests.contains(endpoint.id) { ProgressView().controlSize(.mini) }
                            else if workspace.hasChanges(endpoint.id) { Circle().fill(Color.accentColor).frame(width: 5, height: 5).padding(.top, 5).help("Unsaved changes") }
                        }.padding(.vertical, 5).tag(endpoint.id).help(endpoint.method + " " + endpoint.path)
                    }
                }.listStyle(.sidebar).padding(.horizontal, -10)
            }
        }.padding(.horizontal, 12).background(Theme.panel)
    }

    private var compactNavigation: some View {
        VStack(spacing: 8) {
            search
            Menu {
                ForEach(filtered) { endpoint in
                    Button(endpoint.method + " · " + endpoint.name) { workspace.select(endpoint.source, project: project) }
                }
                if filtered.isEmpty { Text("No matching requests") }
            } label: {
                Text(selected.map { $0.method + " · " + $0.name } ?? "Choose a request").lineLimit(1)
            }.menuStyle(.borderlessButton).frame(maxWidth: .infinity, alignment: .leading).accessibilityLabel("Choose API request")
        }.padding(.horizontal, 16).padding(.vertical, 10).background(Theme.panel)
    }

    @ViewBuilder private var detail: some View {
        if let selected, let draft = workspace.drafts[selected.id] {
            APIRequestDetail(project: project, endpoint: selected.source, workspace: workspace,
                             draft: Binding(get: { workspace.drafts[selected.id] ?? draft }, set: { workspace.drafts[selected.id] = $0 }),
                             openEnvironment: { showEnvironment = true })
                .id(selected.id)
        } else { ContentUnavailableView("Choose a request", systemImage: "sidebar.left") }
    }

    @ViewBuilder private var environment: some View {
        if let plan = project.apiCollection, plan.startupNote != nil || !(plan.composeFiles ?? []).isEmpty {
            DisclosureGroup("Project environment", isExpanded: $showEnvironment) {
                VStack(alignment: .leading, spacing: 10) {
                    if let note = plan.startupNote { Text(note).font(.caption).foregroundStyle(.secondary) }
                    if !(plan.composeFiles ?? []).isEmpty {
                        HStack {
                            composeButton("Start project", ["up", "--build", "-d"])
                            composeButton("Status", ["ps", "--all"])
                            composeButton("Logs", ["logs", "--tail", "40", "--no-color"])
                            Spacer()
                            composeButton("Stop", ["stop"])
                        }.disabled(workspace.busy)
                        Text((["docker"] + plan.composeArguments(projectID: project.id) + ["up", "--build", "-d"]).joined(separator: " "))
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if !workspace.log.isEmpty {
                        ScrollView { SelectableMessageText(workspace.log, markdown: false, font: .monospacedSystemFont(ofSize: 11, weight: .regular)) }
                            .frame(maxHeight: 100)
                    }
                }.padding(.top, 10)
            }.font(.system(size: 12)).padding(.horizontal, 18).padding(.bottom, 12)
        }
    }

    private func composeButton(_ title: String, _ arguments: [String]) -> some View {
        Button(title) { Task { await workspace.compose(arguments, project: project, environment: model.gitEnvironment) } }
    }
    private func notice(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(color.opacity(0.06))
    }
}

private struct APIRequestDetail: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let endpoint: APIEndpoint
    @Bindable var workspace: APIWorkspace
    @Binding var draft: APIRequestDraft
    var openEnvironment: () -> Void
    @State private var section = ""
    @State private var resizedRequestHeight: CGFloat?
    @State private var dragStartHeight: CGFloat?

    private var sending: Bool { workspace.runningRequests.contains(endpoint.id) }
    private var sections: [String] {
        switch draft.method {
        case "GRAPHQL": ["Operation", "Variables", "Headers", "Compare"]
        case "GRPC": ["Message", "Metadata", "Compare"]
        default: ["Parameters", "Headers", "Body", "Compare"]
        }
    }
    private var requestURL: String { draft.requestURL() }
    private var initialSection: String {
        if draft.method == "GRAPHQL" { return "Operation" }
        if draft.method == "GRPC" { return "Message" }
        return !draft.body.isEmpty && !["GET", "HEAD"].contains(draft.method) ? "Body" : "Parameters"
    }

    var body: some View {
        GeometryReader { geometry in
            let height = requestHeight(in: geometry.size.height)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(endpoint.name).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                            Spacer(minLength: 8)
                            Button("Source", systemImage: "chevron.left.forwardslash.chevron.right") { model.openLocation(path: endpoint.source, line: endpoint.line ?? 1, root: project.url) }
                                .help(endpoint.source + ":" + String(endpoint.line ?? 1))
                            Button(workspace.hasChanges(endpoint.id) ? "Save changes" : "Saved", systemImage: workspace.hasChanges(endpoint.id) ? "square.and.arrow.down" : "checkmark") {
                                workspace.save(endpoint, project: project, model: model)
                            }.disabled(!workspace.hasChanges(endpoint.id) || sending)
                        }
                        if let error = workspace.requestErrors[endpoint.id] { Text(error).font(.caption).foregroundStyle(.red) }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Base URL").font(.caption).foregroundStyle(.secondary)
                            TextField(draft.method == "GRPC" ? "grpc://localhost:9090" : "http://localhost:8080", text: $draft.baseURL)
                                .textFieldStyle(.roundedBorder).accessibilityLabel("API base URL")
                        }.disabled(sending)
                        HStack(spacing: 8) {
                            if APICollection.methods.contains(endpoint.method) {
                                Picker("Method", selection: $draft.method) {
                                    ForEach(APICollection.methods, id: \.self) { Text($0).tag($0) }
                                }.labelsHidden().frame(width: 94).accessibilityLabel("HTTP method").disabled(sending)
                            } else { APIMethodBadge(method: endpoint.method) }
                            TextField(draft.method == "GRPC" ? "package.Service/Method" : "/path?query=value", text: $draft.path)
                                .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                                .accessibilityLabel("API request path").disabled(sending)
                            if sending {
                                Button("Cancel", systemImage: "stop.fill") { workspace.cancel(endpoint.id) }
                            } else {
                                Button("Send", systemImage: "paperplane.fill") {
                                    workspace.send(endpoint, project: project, environment: model.gitEnvironment)
                                }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                                    .disabled(!draft.validationErrors.isEmpty)
                                    .help("Send request (⌘Return)")
                                    #if DEBUG
                                        .background(DebugViewMarker(name: "api-send"))
                                    #endif
                            }
                        }
                        HStack {
                            Text(requestURL).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            CopyButton(text: requestURL).accessibilityLabel("Copy request URL")
                        }
                        if !draft.validationErrors.isEmpty {
                            Label(draft.validationErrors.joined(separator: "\n"), systemImage: "exclamationmark.circle")
                                .font(.caption).foregroundStyle(Theme.attention).fixedSize(horizontal: false, vertical: true)
                        }
                        if workspace.canUndoRestore(endpoint.id) {
                            HStack {
                                Text("Restored request from history").foregroundStyle(.secondary)
                                Button("Undo restore") { workspace.undoRestore(endpoint.id) }.disabled(sending)
                            }.font(.caption)
                        }
                        Picker("Request section", selection: $section) {
                            ForEach(sections, id: \.self) { Text($0).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden()
                        requestFields.disabled(sending)
                        if let note = endpoint.note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }.padding(16)
                }.frame(height: height)
                requestDivider(height: height, available: geometry.size.height)
                APIResponseArea(result: workspace.result(for: endpoint.id), sending: sending,
                                history: workspace.history.runs(for: endpoint.id),
                                selectedRun: Binding(get: { workspace.selectedRunIDs[endpoint.id] }, set: { workspace.selectedRunIDs[endpoint.id] = $0 }),
                                rerun: { run in
                                    workspace.send(endpoint, project: project, environment: model.gitEnvironment,
                                                   compare: run.comparison != nil, snapshot: run.request)
                                }, restore: { workspace.restore($0) },
                                project: project, workspace: workspace, openEnvironment: openEnvironment)
                    .frame(maxHeight: .infinity)
            }
        }
        .onAppear { if section.isEmpty { section = initialSection } }
        .onChange(of: draft.method) { _, _ in if !sections.contains(section) { section = sections[0] } }
    }

    /// A short form should not inherit half of a very tall window's unused space.
    /// Keep a compact form on smaller windows and give extra height to the response.
    private func requestHeight(in available: CGFloat) -> CGFloat {
        let preferred: CGFloat = ["Parameters", "Compare"].contains(section) ? 320 : 390
        let minimum = min(210, available * 0.5)
        let maximum = max(minimum, available - min(150, available * 0.35) - 7)
        return min(maximum, max(minimum, resizedRequestHeight ?? min(preferred, available * 0.52)))
    }

    private func requestDivider(height: CGFloat, available: CGFloat) -> some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
            .overlay { Capsule().fill(.secondary.opacity(0.45)).frame(width: 28, height: 3) }
            .frame(height: 7).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartHeight == nil { dragStartHeight = height }
                    resizedRequestHeight = (dragStartHeight ?? height) + value.translation.height
                    resizedRequestHeight = requestHeight(in: available)
                }
                .onEnded { _ in dragStartHeight = nil })
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .accessibilityElement().accessibilityLabel("Resize request and response panes")
            .accessibilityAdjustableAction { direction in
                resizedRequestHeight = height + (direction == .increment ? 40 : -40)
                resizedRequestHeight = requestHeight(in: available)
            }
    }

    @ViewBuilder private var requestFields: some View {
        switch section {
        case "Headers", "Metadata":
            editor($draft.headers, title: section == "Metadata" ? "Request metadata" : "Request headers", hint: "One Name: value header per line")
        case "Body", "Operation", "Message":
            editor($draft.body, title: section == "Operation" ? "GraphQL operation" : section == "Message" ? "gRPC message" : "Request body",
                   hint: section == "Operation" ? "Write the GraphQL query or mutation." : "Enter the request payload.")
        case "Variables":
            editor($draft.variables, title: "GraphQL variables", hint: "A JSON object, for example {\"limit\": 10}")
        case "Compare":
            VStack(alignment: .leading, spacing: 8) {
                Text("Send the same request to a second environment and compare response bodies.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Second base URL", text: $draft.comparisonBaseURL).textFieldStyle(.roundedBorder).accessibilityLabel("Comparison base URL")
                    Button("Compare responses") { workspace.send(endpoint, project: project, environment: model.gitEnvironment, compare: true) }
                        .disabled(!draft.validationErrors.isEmpty || { var other = draft; other.baseURL = draft.comparisonBaseURL; return !other.validationErrors.isEmpty }())
                }
            }
        default:
            VStack(alignment: .leading, spacing: 10) {
                if !draft.pathParameterNames.isEmpty {
                    Text("Path parameters").font(.caption).foregroundStyle(.secondary)
                    ForEach(draft.pathParameterNames, id: \.self) { name in
                        HStack {
                            Text(name).font(.system(size: 12, design: .monospaced)).frame(width: 90, alignment: .leading)
                            TextField("Required", text: Binding(get: { draft.pathParameters[name] ?? "" }, set: { draft.pathParameters[name] = $0 }))
                                .textFieldStyle(.roundedBorder).accessibilityLabel("Path parameter " + name)
                        }
                    }
                }
                HStack {
                    Text("Query parameters").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add", systemImage: "plus") { draft.queryParameters.append(.init()) }
                        .accessibilityLabel("Add query parameter")
                }
                ForEach(Array(draft.queryParameters.indices), id: \.self) { index in
                    HStack {
                        TextField("Name", text: queryField(index, \.name)).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Query parameter name \(index + 1)")
                        TextField("Value", text: queryField(index, \.value)).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Query parameter value \(index + 1)")
                        Button {
                            if draft.queryParameters.indices.contains(index) { draft.queryParameters.remove(at: index) }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).accessibilityLabel("Remove query parameter \(index + 1)")
                    }
                }
                if draft.queryParameters.isEmpty { Text("No query parameters").font(.caption).foregroundStyle(.tertiary) }
            }
        }
    }

    private func queryField(_ index: Int, _ field: WritableKeyPath<APIRequestDraft.QueryParameter, String>) -> Binding<String> {
        Binding(get: { draft.queryParameters.indices.contains(index) ? draft.queryParameters[index][keyPath: field] : "" }, set: { value in
            var parameters = draft.queryParameters
            guard parameters.indices.contains(index) else { return }
            parameters[index][keyPath: field] = value
            draft.queryParameters = parameters
        })
    }

    private func editor(_ text: Binding<String>, title: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RequestCodeEditor(text: text, label: title)
                .padding(8).frame(minHeight: 100, idealHeight: 120, maxHeight: 180)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.hairline) }
                .accessibilityLabel(title)
            Text(hint).font(.caption).foregroundStyle(.secondary)
            if title == "Request body" || title == "gRPC message", let error = draft.bodyValidationError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct APIResponseArea: View {
    let result: APIWorkspace.RequestResult?
    let sending: Bool
    let history: [APIRequestRun]
    @Binding var selectedRun: UUID?
    var rerun: (APIRequestRun) -> Void
    var restore: (APIRequestRun) -> Void
    let project: Project
    @Bindable var workspace: APIWorkspace
    var openEnvironment: () -> Void
    @State private var section = "Body"
    @State private var inspectedRun: APIRequestRun?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Response").font(.system(size: 12, weight: .semibold))
                Spacer()
                if sending { ProgressView().controlSize(.mini); Text("Sending…").font(.caption).foregroundStyle(.secondary) }
                if !history.isEmpty {
                    Menu("History (\(history.count))") {
                        Button("Latest response") { selectedRun = nil }
                        Divider()
                        ForEach(history) { run in
                            Button { selectedRun = run.id } label: {
                                let title = run.date.formatted(date: .abbreviated, time: .standard) + " · " + run.request.method + " " + run.request.resolvedPath + " · " + run.primary.status
                                if selectedRun == run.id { Label(title, systemImage: "checkmark") }
                                else { Text(title) }
                            }
                        }
                    }.fixedSize().accessibilityLabel("Response history")
                    if let result {
                        Button { inspectedRun = result } label: { Image(systemName: "doc.text.magnifyingglass") }
                            .help("View the saved request").accessibilityLabel("View request snapshot")
                        Button { rerun(result) } label: { Image(systemName: "arrow.clockwise") }
                            .disabled(sending || !result.request.validationErrors.isEmpty)
                            .help("Rerun this request snapshot").accessibilityLabel("Rerun response request")
                    }
                }
                Picker("Response section", selection: $section) {
                    ForEach(["Body", "Headers", "Raw"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
            }.padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if let result {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !result.difference.isEmpty { Label(result.difference, systemImage: "arrow.left.arrow.right").font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            Text(selectedRun == nil ? "Latest response" : "Earlier response · saved request")
                            Spacer()
                            Button("View request") { inspectedRun = result }
                        }.font(.caption).foregroundStyle(.secondary)
                        Text(result.date, format: .dateTime.hour().minute().second()).font(.caption).foregroundStyle(.secondary)
                        APIResponseCard(response: result.primary, target: result.target, section: section,
                                        project: project, workspace: workspace, openEnvironment: openEnvironment)
                        if let comparison = result.comparison {
                            APIResponseCard(response: comparison, target: result.comparisonTarget ?? "", section: section,
                                            project: project, workspace: workspace, openEnvironment: openEnvironment)
                        }
                    }.padding(16)
                }
                #if DEBUG
                    .background(DebugViewMarker(name: result.primary.raw.contains("HTTP 200") || result.primary.raw.contains("gRPC OK") ? "api-response-ok" : "api-response"))
                #endif
            } else {
                VStack(spacing: 8) {
                    Image(systemName: sending ? "arrow.up.arrow.down" : "tray").font(.system(size: 24, weight: .light)).foregroundStyle(.secondary)
                    Text(sending ? "Waiting for a response" : "Send a request to see the response").font(.system(size: 13, weight: .medium))
                    Text(sending ? "You can cancel or switch to another request." : "Status, timing, headers and body will appear here.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(Theme.panel)
            .popover(item: $inspectedRun) { run in
                APIRequestSnapshotView(run: run, canRestore: !sending) {
                    restore(run); inspectedRun = nil
                }.frame(width: 540, height: 500)
            }
    }
}

private struct APIResponseCard: View {
    let response: APIResponsePreview
    let target: String
    let section: String
    let project: Project
    @Bindable var workspace: APIWorkspace
    var openEnvironment: () -> Void
    private var text: String {
        switch section {
        case "Headers": response.headers.isEmpty ? "No response headers." : response.headers
        case "Raw": response.raw
        default: response.body.isEmpty ? "Empty response body." : response.body
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(response.status, systemImage: response.isFailure ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(response.isFailure ? .red : .green)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(response.bodyBytes), countStyle: .file) + " body").font(.caption).foregroundStyle(.secondary)
                CopyButton(text: section == "Headers" ? response.headers : section == "Raw" ? response.raw : response.body)
                    .accessibilityLabel("Copy response " + section.lowercased())
            }
            Text(target).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if response.isConnectionFailure {
                APIConnectionRecovery(project: project, target: target, workspace: workspace, openEnvironment: openEnvironment)
            }
            Divider()
            SelectableMessageText(text, markdown: false, font: .monospacedSystemFont(ofSize: 12, weight: .regular), lineSpacing: 2)
                .accessibilityLabel("API response " + section.lowercased())
        }.padding(12).background(Theme.canvas, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline) }
    }
}

private struct APIConnectionRecovery: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let target: String
    @Bindable var workspace: APIWorkspace
    var openEnvironment: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Check the server address and whether the project is running.").font(.caption).foregroundStyle(.secondary)
            if !(project.apiCollection?.composeFiles ?? []).isEmpty {
                HStack {
                    if APICollection.isLocalTarget(target) {
                        Button("Start project", systemImage: "play.fill") { compose(["up", "--build", "-d"]) }
                    }
                    Button("View logs", systemImage: "text.alignleft") { compose(["logs", "--tail", "40", "--no-color"]) }
                    Button("Project setup") { openEnvironment() }
                    if workspace.busy { ProgressView().controlSize(.mini) }
                }.disabled(workspace.busy)
            } else if project.apiCollection?.startupNote != nil {
                Button("View project setup") { openEnvironment() }
            }
        }
    }

    private func compose(_ action: [String]) {
        openEnvironment()
        Task { await workspace.compose(action, project: project, environment: model.gitEnvironment) }
    }
}

private struct APIRequestSnapshotView: View {
    let run: APIRequestRun
    let canRestore: Bool
    var restore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Saved request").font(.headline)
                Spacer()
                Button("Restore to editor", systemImage: "arrow.uturn.backward") { restore() }.disabled(!canRestore)
            }
            Text(run.date, format: .dateTime.month().day().hour().minute().second()).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field("Method and URL", run.request.method + " " + run.target)
                    field("Headers", run.request.headers.isEmpty ? "No headers" : run.request.headers)
                    field(run.request.method == "GRAPHQL" ? "Operation" : "Body", run.request.body.isEmpty ? "Empty body" : run.request.body)
                    if run.request.method == "GRAPHQL" { field("Variables", run.request.variables) }
                    if run.comparison != nil { field("Comparison destination", run.request.requestURL(base: run.request.comparisonBaseURL)) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(18)
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: value).accessibilityLabel("Copy saved request " + title.lowercased())
            }
            SelectableMessageText(value, markdown: false, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
                .accessibilityLabel("Saved request " + title.lowercased())
        }
    }
}

private struct APIMethodBadge: View {
    let method: String
    private var color: Color {
        switch method {
        case "GET": .green
        case "POST": .blue
        case "DELETE": .red
        case "PUT", "PATCH": .orange
        default: .purple
        }
    }
    var body: some View {
        Text(method).font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(color).padding(.horizontal, 6).padding(.vertical, 4)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
    }
}
