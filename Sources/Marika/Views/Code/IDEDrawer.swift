import MarikaCore
import SwiftUI

struct IDEDrawer: View {
    @Bindable var ide: IDEWorkspace
    @State private var expanded: [String: [JSONValue]] = [:]
    @State private var expandedNames: Set<String> = []
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                ForEach(["Problems", "Code", "Tests", "Debug"], id: \.self) { tab in
                    Button(tab) { ide.panel = tab }.buttonStyle(.plain).foregroundStyle(ide.panel == tab ? Color.accentColor : .secondary)
                }
                Spacer()
                Text(ide.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button { ide.showsPanel = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }.font(.system(size: 11, weight: .semibold)).padding(10).background(Theme.chrome)
            Divider()
            switch ide.panel {
            case "Tests": tests
            case "Debug": debugger
            case "Code": code
            default: problems
            }
        }.frame(minHeight: 190, idealHeight: 255, maxHeight: 350).background(Theme.panel)
    }
    private var problems: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 7) {
                if ide.problemCount == 0 { Text("No diagnostics reported").foregroundStyle(.secondary).padding(14) }
                ForEach(ide.diagnostics.keys.sorted(), id: \.self) { path in
                    ForEach(Array((ide.diagnostics[path] ?? []).enumerated()), id: \.offset) { _, item in
                        Button {
                            Task { await ide.editor.open(path); ide.editor.reveal(line: (item["range"]?["start"]?["line"]?.int ?? 0) + 1, column: (item["range"]?["start"]?["character"]?.int ?? 0) + 1) }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: item["severity"]?.int == 1 ? "xmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(item["severity"]?.int == 1 ? .red : .orange)
                                Text(item["message"]?.string ?? "Diagnostic").multilineTextAlignment(.leading)
                                Spacer()
                                Text(path + ":" + String((item["range"]?["start"]?["line"]?.int ?? 0) + 1)).foregroundStyle(.secondary).lineLimit(1)
                            }.font(.system(size: 11)).padding(.horizontal, 12)
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(.vertical, 8)
        }
    }
    private var code: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !ide.message.isEmpty { Text(ide.message).textSelection(.enabled).font(.callout) }
                ForEach(ide.results) { result in
                    Button { ide.select(result) } label: {
                        HStack { Text(result.title).lineLimit(1); Spacer(); Text(result.detail).foregroundStyle(.secondary).lineLimit(1) }
                    }.buttonStyle(.plain)
                }
                ForEach(ide.pendingEdits, id: \.0.id) { document, before, after in
                    DisclosureGroup(document.path) {
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading) { Text("Before").foregroundStyle(.secondary); Text(before).textSelection(.enabled) }.frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                            VStack(alignment: .leading) { Text("After").foregroundStyle(.secondary); Text(after).textSelection(.enabled) }.frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.system(size: 11, design: .monospaced))
                    }
                }
                if !ide.pendingEdits.isEmpty {
                    HStack { Button("Apply to drafts") { ide.applyEdits() }.buttonStyle(.borderedProminent); Button("Discard") { ide.pendingEdits = [] } }
                }
            }.font(.system(size: 12)).padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var tests: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Framework", selection: $ide.testFramework) { ForEach(["Go", "Swift", "Python"], id: \.self) { Text($0) } }.labelsHidden().frame(width: 110)
                Button("Discover") { ide.discoverTests() }.disabled(ide.testRunning)
                Button("Run all") { ide.runTest() }.disabled(ide.testRunning)
                if ide.testRunning { ProgressView().controlSize(.small); Button("Stop") { ide.cancelTests() } }
                Spacer()
                Text("\(ide.tests.count) \(ide.tests.count == 1 ? "test" : "tests")").foregroundStyle(.secondary)
            }.controlSize(.small).padding(.horizontal, 10).padding(.top, 8)
            HSplitView {
                List(ide.tests) { test in
                    HStack {
                        Image(systemName: ide.testStatuses[test.id] == "pass" ? "checkmark.circle.fill" : ide.testStatuses[test.id] == "fail" ? "xmark.circle.fill" : "circle")
                            .foregroundStyle(ide.testStatuses[test.id] == "pass" ? .green : ide.testStatuses[test.id] == "fail" ? .red : .secondary)
                        Text(test.name).font(.system(size: 11)).lineLimit(1)
                        Spacer()
                        Button { ide.runTest(test) } label: { Image(systemName: "play.fill") }.buttonStyle(.plain).disabled(ide.testRunning)
                    }.help(test.target)
                }.frame(minWidth: 180, idealWidth: 260)
                ScrollView { Text(ide.testOutput).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) }.frame(minWidth: 150)
            }
        }
    }
    private var debugger: some View {
        VStack(spacing: 6) {
            if !ide.debug.isActive { TextField("Go program directory (defaults to project root)", text: $ide.debugProgram).textFieldStyle(.roundedBorder).font(.caption).padding(.horizontal, 8) }
            HStack {
                Text(ide.debug.status).font(.caption.bold())
                Button("Start") { ide.launchDebugger() }.disabled(ide.debug.isActive)
                ForEach([("Continue", "continue"), ("Step over", "next"), ("Step in", "stepIn"), ("Step out", "stepOut")], id: \.1) { title, command in
                    Button(title) { Task { await ide.debug.action(command) } }.disabled(!ide.debug.isPaused)
                }
                Button("Pause") { Task { await ide.debug.action("pause") } }.disabled(!ide.debug.isActive || ide.debug.isPaused)
                Button("Stop") { Task { await ide.debug.stop() } }.disabled(!ide.debug.isActive)
                Spacer()
            }.controlSize(.small).padding(8)
            if let error = ide.debug.error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            HSplitView {
                List(ide.debug.frames, id: \.self) { frame in
                    Button(frame["name"]?.string ?? "Frame") {
                        Task {
                            await ide.debug.inspect(frame)
                            let root = ide.context.runtime?.directory ?? FilePath.resolved(ide.editor.root.path)
                            if let path = frame["source"]?["path"]?.string, path.hasPrefix(root + "/") {
                                await ide.editor.open(String(path.dropFirst(root.count + 1))); ide.editor.reveal(line: frame["line"]?.int ?? 1)
                            }
                        }
                    }.buttonStyle(.plain).font(.caption)
                }.frame(minWidth: 130, idealWidth: 210)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(ide.debug.variables, id: \.self) { variable in
                            let name = variable["name"]?.string ?? "Value"
                            DisclosureGroup(isExpanded: Binding(get: { expandedNames.contains(name) }, set: { value in
                                if value { expandedNames.insert(name); Task { expanded[name] = await ide.debug.expand(variable) } }
                                else { expandedNames.remove(name) }
                            })) {
                                Text(variable["value"]?.string ?? "").textSelection(.enabled)
                                ForEach(expanded[name] ?? [], id: \.self) { child in
                                    Text((child["name"]?.string ?? "") + " = " + (child["value"]?.string ?? ""))
                                }
                            } label: { Text(name + " = " + (variable["value"]?.string ?? "")) }
                        }
                        TextField("Watch expression", text: $ide.watchExpression).onSubmit { Task { await ide.debug.evaluate(ide.watchExpression) } }
                        ForEach(ide.debug.watches.keys.sorted(), id: \.self) { key in Text(key + " = " + (ide.debug.watches[key] ?? "")) }
                        Text(ide.debug.output).textSelection(.enabled)
                    }.font(.system(size: 11, design: .monospaced)).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 170)
            }
        }
    }
}
