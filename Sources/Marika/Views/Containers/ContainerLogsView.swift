import AppKit
import Charts
import MarikaCore
import SwiftUI
import UniformTypeIdentifiers

struct ContainerLogsView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let workspace: ContainerWorkspace
    @Bindable var logs: ContainerLogsWorkspace
    @State private var connectionSheet = false
    @State private var width: CGFloat = 1000
    @State private var height: CGFloat = 600
    private var sources: [ContainerResource] { workspace.inventory.resources.filter { [.container, .pod, .deployment, .statefulSet, .daemonSet, .job, .cronJob, .service].contains($0.kind) }.sorted { $0.name < $1.name } }
    private var source: ContainerResource? { sources.first { $0.id == logs.sourceID } }
    private var containers: [String] {
        guard let source else { return [] }
        return Set(workspace.relatedPods(source).flatMap { $0.containers.map(\.name) }).sorted()
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { heading; Spacer(minLength: 8); connectionActions }
                    VStack(alignment: .leading, spacing: 10) { heading; connectionActions }
                }
                if logs.backend == .runtime {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { workloadPicker; containerPicker }
                        VStack(alignment: .leading, spacing: 10) { workloadPicker; containerPicker }
                    }
                } else {
                    TextField(#"LogQL, e.g. {namespace="app"} |= "error""#, text: $logs.query).textFieldStyle(.workspace).font(.system(size: 12, design: .monospaced))
                        .onSubmit(run)
                }
                HStack(spacing: 12) {
                    WorkspaceSelect(title: "Range", selection: $logs.since, options: [300, 900, 3_600, 21_600, 86_400], label: {
                        switch $0 { case 300: "Last 5 minutes"; case 900: "Last 15 minutes"; case 3_600: "Last hour"; case 21_600: "Last 6 hours"; default: "Last 24 hours" }
                    }, height: 32).frame(maxWidth: 190)
                    Toggle("Live", isOn: $logs.live).toggleStyle(.checkbox)
                        #if DEBUG
                        .background(DebugViewMarker(name: "log-live"))
                        #endif
                    if width >= 600 { Toggle("Follow", isOn: $logs.follow).toggleStyle(.checkbox) }
                    Spacer(minLength: 0)
                    if logs.isLoading { ProgressView().controlSize(.small) }
                    Button(logs.live ? "Start live" : "Run query", action: run).buttonStyle(WorkspaceButtonStyle(kind: .primary, compact: true)).disabled(logs.isLoading)
                        #if DEBUG
                        .background(DebugViewMarker(name: "log-run"))
                        #endif
                    Button("Stop") { logs.stop() }.buttonStyle(WorkspaceButtonStyle(compact: true)).disabled(!logs.isRunning && !logs.isLoading)
                        #if DEBUG
                        .background(DebugViewMarker(name: "log-stop"))
                        #endif
                }
                HStack(spacing: 10) {
                    WorkspaceSearchField(placeholder: "Filter returned lines", text: $logs.search)
                        #if DEBUG
                        .background(DebugViewMarker(name: "log-search"))
                        #endif
                    WorkspaceSelect(title: "Level", selection: $logs.severity, options: [.all, .warningsAndErrors, .errors], label: {
                        switch $0 { case .all: "All levels"; case .warningsAndErrors: "Warnings + errors"; case .errors: "Errors" }
                    }, height: 36).frame(width: width < 600 ? 120 : 165)
                    Menu {
                        Toggle("Follow new entries", isOn: $logs.follow)
                        Button("Copy logs") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(exportText, forType: .string) }.disabled(logs.entries.isEmpty)
                        Button("Save logs…", action: save).disabled(logs.entries.isEmpty)
                    } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Log options")
                }
                if let error = logs.error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if let note = logs.note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }.padding(16).background(Theme.panel)
            Divider()
            if !logs.entries.isEmpty, height >= 500 {
                volume.padding(.horizontal, 16).padding(.top, 8)
                Divider()
            }
            entries
            if let selected = logs.selected {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(selected.source).font(.caption.weight(.semibold)); Spacer(); Button { logs.selectedID = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                    ScrollView {
                        if selected.fields.isEmpty { Text(selected.message).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        else { ForEach(selected.fields, id: \.0) { key, value in HStack(alignment: .top) { Text(key).foregroundStyle(.secondary).frame(width: 130, alignment: .leading); Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.font(.system(size: 11, design: .monospaced)) } }
                    }.frame(maxHeight: height < 440 ? 72 : 160)
                }.padding(12).background(Theme.panel)
            }
            HStack {
                Circle().fill(logs.isRunning && logs.live ? Color.green : .secondary).frame(width: 6, height: 6)
                Text(logs.isRunning && logs.live ? (logs.backend == .loki ? "Live · refreshing every 5s" : "Live") : "Snapshot")
                Text("· \(logs.entries.count) shown · \(logs.buffer.entries.count) buffered")
                if logs.buffer.dropped > 0 { Text("· \(logs.buffer.dropped) older lines dropped") }
                Spacer(); Button("Clear") { logs.buffer.clear(); logs.selectedID = nil }.buttonStyle(WorkspaceButtonStyle(kind: .quiet, compact: true))
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 6).background(Theme.panel)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { width = $0.width; height = $0.height }
        .onAppear {
            chooseSource()
            if logs.query == #"{namespace="default"}"#, workspace.settings.namespace != "*" { logs.query = "{namespace=" + String(decoding: (try? JSONValue.string(workspace.settings.namespace).serialized()) ?? Data("\"default\"".utf8), as: UTF8.self) + "}" }
        }
        .onChange(of: sources.map(\.id)) { _, _ in chooseSource() }
        .onChange(of: logs.backend) { _, _ in logs.stop(); logs.buffer.clear(); logs.selectedID = nil; logs.error = nil; chooseSource() }
        .onChange(of: logs.sourceID) { _, _ in if logs.backend == .runtime { logs.stop(); logs.buffer.clear(); logs.selectedID = nil; logs.container = "" } }
        .onChange(of: logs.container) { _, _ in if logs.backend == .runtime { logs.stop() } }
        .onChange(of: logs.since) { _, _ in logs.stop() }
        .onChange(of: logs.live) { _, _ in logs.stop() }
        .onDisappear { logs.stop() }
        .sheet(isPresented: $connectionSheet) { ContainerLogConnectionView(workspace: workspace, projectID: project.id) }
        #if DEBUG
        .background(DebugViewMarker(name: "containers-logs-view"))
        #endif
    }

    private var heading: some View {
        HStack(spacing: 12) {
            Text("Logs").font(.title2.weight(.semibold))
            WorkspaceTabPicker(title: "Source", selection: $logs.backend, options: [.runtime, .loki], label: { $0 == .runtime ? "Containers" : "Loki history" }).frame(width: 225)
                #if DEBUG
                .background(DebugViewMarker(name: "log-backend"))
                #endif
        }
    }
    private var connectionActions: some View {
        HStack(spacing: 8) {
            if let text = workspace.settings.logConnection?.grafanaURL, !text.isEmpty {
                Button("Open Grafana") { model.browser(for: project).navigate(text); model.switchPanel(.browser) }
                    .buttonStyle(WorkspaceButtonStyle(kind: .quiet, compact: true))
            }
            Button("Connections…") { connectionSheet = true }
                .buttonStyle(WorkspaceButtonStyle(compact: true))
                #if DEBUG
                .background(DebugViewMarker(name: "log-connections"))
                #endif
        }
    }
    private var workloadPicker: some View {
        WorkspaceSelect(title: "Workload", selection: $logs.sourceID, options: ["", "all"] + sources.map(\.id), label: { id in
            if id == "all" { return "All current pods / containers (up to 8)" }
            guard let source = sources.first(where: { $0.id == id }) else { return "Choose a workload or pod" }
            return source.name + " · " + source.kind.rawValue + (source.namespace.isEmpty ? "" : " · " + source.namespace)
        }, height: 32)
            #if DEBUG
            .background(DebugViewMarker(name: "log-source"))
            #endif
    }
    @ViewBuilder private var containerPicker: some View {
        if workspace.settings.provider == .kubernetes {
            WorkspaceSelect(title: "Container", selection: $logs.container, options: [""] + containers,
                label: { $0.isEmpty ? "All containers" : $0 }, height: 32).frame(maxWidth: 230)
        }
    }
    private var entries: some View {
        ScrollViewReader { proxy in
            Group {
                if logs.buffer.entries.isEmpty {
                    ContentUnavailableView(logs.isRunning ? "Waiting for logs…" : "Explore your logs", systemImage: "text.alignleft",
                        description: Text(logs.backend == .loki ? "Connect a Loki endpoint and run a LogQL query for historical logs." : "Choose a workload, set a time range, then run a query or start live tailing."))
                } else {
                    List(selection: $logs.selectedID) {
                        ForEach(logs.entries) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                Text(entry.timestamp, format: .dateTime.hour().minute().second()).foregroundStyle(.secondary).frame(width: 75, alignment: .leading)
                                Text(entry.level == .unknown ? "—" : entry.level.rawValue.uppercased()).foregroundStyle(entry.level == .error ? .red : entry.level == .warning ? .orange : .secondary).frame(width: 52, alignment: .leading)
                                VStack(alignment: .leading, spacing: 3) { Text(entry.message).lineLimit(2); Text(entry.source).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1) }
                            }.font(.system(size: 11, design: .monospaced)).padding(.vertical, 3).tag(entry.id).id(entry.id)
                        }
                    }.listStyle(.plain)
                }
            }.onChange(of: logs.buffer.entries.last?.id) { _, _ in if logs.follow, let id = logs.entries.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
        }
    }
    private var volume: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Loaded log volume · filtered lines").font(.system(size: 10)).foregroundStyle(.secondary)
            Chart(ContainerLogChart.buckets(logs.entries, start: logs.start, end: logs.end)) { bucket in
                let end = bucket.start.addingTimeInterval(max(1, logs.end.timeIntervalSince(logs.start)) / 40)
                RectangleMark(xStart: .value("Start", bucket.start), xEnd: .value("End", end), yStart: .value("Base", 0), yEnd: .value("Lines", bucket.count - bucket.errors)).foregroundStyle(Theme.action.opacity(0.55))
                RectangleMark(xStart: .value("Start", bucket.start), xEnd: .value("End", end), yStart: .value("Base", bucket.count - bucket.errors), yEnd: .value("Lines", bucket.count)).foregroundStyle(.red.opacity(0.75))
            }.chartXScale(domain: logs.start...logs.end).chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }.chartYAxis { AxisMarks(values: .automatic(desiredCount: 2)) }.frame(height: 70)
        }
    }
    private var exportText: String { logs.entries.map { $0.timestamp.ISO8601Format() + " [" + $0.source + "] " + $0.message }.joined(separator: "\n") }
    private func chooseSource() {
        guard logs.backend == .runtime else { return }
        if logs.sourceID == "all" { return }
        if !sources.contains(where: { $0.id == logs.sourceID }) {
            logs.sourceID = workspace.selected.flatMap { selected in sources.contains(where: { $0.id == selected.id }) ? selected.id : nil } ?? sources.first(where: { $0.kind == .container || $0.kind == .pod })?.id ?? ""
        }
    }
    private func save() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "container-logs.txt"; panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url { do { try exportText.write(to: url, atomically: true, encoding: .utf8) } catch { logs.error = error.localizedDescription } }
    }
    private func run() {
        if logs.backend == .loki {
            guard let connection = workspace.settings.logConnection, !connection.endpoint.isEmpty else { connectionSheet = true; return }
            workspace.queryLoki(connection)
        } else {
            guard let target = workspace.target else { return }
            let resources: [ContainerResource]
            if logs.sourceID == "all" { resources = sources.filter { $0.kind == .pod || $0.kind == .container } }
            else if let source { resources = source.kind == .container ? [source] : workspace.relatedPods(source) }
            else { resources = [] }
            logs.runRuntime(resources.filter { logs.container.isEmpty || $0.containers.contains(where: { $0.name == logs.container }) }, target: target)
        }
    }
}
