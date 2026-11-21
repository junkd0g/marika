#if DEBUG
import AppKit
import MarikaCore

@MainActor enum DebugWorkspaceSixChecks {
    static func design(_ model: AppModel, showSystem: Bool) throws {
        guard DebugFixtureSettings.value("MARIKA_DATA") != nil, let project = model.selectedProject ?? model.spaceProjects.first else { throw DesignToolError("Isolated project required") }
        model.openProject(project, tab: .design)
        guard let canvas = model.designCanvases[project.id] else { throw DesignToolError("Canvas missing") }
        var doc = DesignDocument(); doc.title = "Copper design system"
        let accent = DesignColorToken(name: "Action / violet", color: DesignColor(hex: "#6254D9")!)
        let type = DesignTypeToken(name: "Button / medium", size: 16, weight: .semibold)
        let space = DesignSpacingToken(name: "Comfortable", value: 20)
        doc.updateColorToken(accent); doc.updateTypeToken(type); doc.designSystem?.spacing = [space]
        let title = doc.add(.text, in: CGRect(x: 0, y: 0, width: 580, height: 70))
        doc.update([title]) { $0.text = "One system. Every screen."; $0.name = "Heading"; $0.fontSize = 34; $0.fontWeight = .bold }
        let button = doc.add(.rectangle, in: CGRect(x: 0, y: 100, width: 220, height: 60))
        doc.update([button]) { $0.name = "Primary button"; $0.text = "Continue"; $0.description = "Submit the current step after validation."; $0.cornerRadius = 12 }
        doc.bindColor(accent.id, to: [button]); doc.bindTypography(type.id, to: [button])
        let component = try doc.saveReusableComponent(name: "Button", variant: "Default", selection: [button])
        doc.update([button]) { $0.opacity = 0.45; $0.text = "Unavailable" }
        _ = try doc.saveReusableComponent(name: "Button", variant: "Disabled", selection: [button], componentID: component)
        let variant = doc.designSystem!.components[0].variants[0].id
        let instance = try doc.insertReusableComponent(component, variantID: variant, at: CGPoint(x: 380, y: 130))
        let frame = doc.add(.frame, in: CGRect(x: 0, y: 240, width: 560, height: 180))
        doc.update([frame]) { $0.name = "Automatic row"; $0.text = "" }
        for (index, label) in ["Plan", "Build", "Review"].enumerated() {
            let id = doc.add(.rectangle, in: CGRect(x: 20 + index * 170, y: 275, width: 145, height: 90))
            doc.update([id]) { $0.name = label; $0.text = label; $0.fill = DesignColor(hex: "#EDEBF9")!; $0.layoutParentID = frame }
        }
        try doc.configureLayout(frame, configuration: DesignAutoLayout(axis: .row, spacingTokenID: space.id))
        canvas.edit { $0 = doc }; canvas.selection = [instance]; canvas.fit()
        canvas.showsSystem = showSystem
        guard canvas.doc.designSystem?.components[0].variants.count == 2, canvas.doc.node(instance)?.reusableInstance != nil else { throw DesignToolError("Reusable variants missing") }
    }
    static func layout(_ model: AppModel, name: String) async throws {
        guard let project = model.selectedProject, let focus = WorkspaceFocus(rawValue: name) else { throw DesignToolError("Layout fixture missing") }
        await model.open(model.selectedSessionID!)
        let controller = model.controllers[model.selectedSessionID!]
        controller?.draft = "Keep this unsent draft"
        model.applyViewPreset(focus.preset, project: project)
        try model.saveViewPreset(name: "My " + name, project: project)
        let layout = model.layout(for: project.id)
        guard layout.panel == focus.preset.primary, layout.secondary == focus.preset.secondary,
              controller?.draft == "Keep this unsent draft", model.project(id: project.id)?.viewPresets?.last?.name == "My " + name else { throw DesignToolError("Layout lost split or draft") }
        guard await model.save() else { throw DesignToolError("Preset did not save") }
    }
    static func importReference(_ model: AppModel, source: String, agent: AgentKind, screenshot: String? = nil, modelID: String? = nil) async throws {
        guard DebugFixtureSettings.value("MARIKA_DATA") != nil, let project = model.selectedProject else { throw DesignToolError("Isolated import fixture required") }
        let importer = DesignImportModel(projectID: project.id, app: model)
        if let screenshot { try await importer.loadReference(from: URL(fileURLWithPath: screenshot)) }
        else { await importer.capturePreview() }
        guard let reference = importer.reference, let image = importer.referenceImage else { throw DesignToolError(importer.error ?? "Reference capture failed") }
        try await model.startDesignImport(projectID: project.id, paths: [source], focus: "Reconstruct the reference welcome card at its measured viewport, with exact visible text and source links.", agent: agent, model: modelID, reference: reference, referenceImage: image)
        model.openDesign(for: project.id)
    }
    static func exportImport(_ model: AppModel, directory: String) async throws {
        guard let run = model.selectedProject?.designImport, let proposal = run.proposal, let reference = run.reference else { throw DesignToolError("Ready reference import required") }
        let root = URL(fileURLWithPath: directory)
        try JSONEncoder().encode(proposal).write(to: root.appendingPathComponent("proposal.json"))
        let fidelity = try await DesignImportFidelity.compare(reference, with: proposal.document)
        try fidelity.reference.write(to: root.appendingPathComponent("reference.png"))
        try fidelity.render.write(to: root.appendingPathComponent("import.png"))
        try fidelity.difference.png.write(to: root.appendingPathComponent("difference.png"))
        let comparison = DesignReferenceComparison(reference: reference, document: proposal.document, sources: Set(run.files.map(\.path)))
        let report = try JSONValue(parsing: JSONEncoder().encode(comparison))
        var values = report.object ?? [:]
        values["changedPixelFraction"] = .double(fidelity.difference.changedFraction)
        values["reference"] = .string(reference.source)
        try JSONValue.object(values).serialized().write(to: root.appendingPathComponent("measurements.json"))
    }
    static func metrics(_ model: AppModel) async throws {
        guard DebugFixtureSettings.value("MARIKA_DATA") != nil, let project = model.selectedProject else { throw ContainerHubError("Isolated fixture required") }
        let inventory = #"{"items":[{"kind":"Pod","metadata":{"name":"api","namespace":"default","uid":"api"},"spec":{"containers":[{"name":"api","image":"copper/api:v2"}]},"status":{"phase":"Running","containerStatuses":[{"name":"api","ready":true,"restartCount":1}]}}]}"#
        let workspace = ContainerWorkspace(project: project, environment: [:], clusterDirectory: project.url, runner: { command in
            if command.arguments.contains("--raw") {
                return ContainerCommandResult(output: #"{"items":[{"metadata":{"name":"api","namespace":"default"},"containers":[{"usage":{"cpu":"820m","memory":"180Mi"}}]}]}"#)
            }
            if command.arguments.contains("events") {
                let date = Date().addingTimeInterval(-300).ISO8601Format()
                return ContainerCommandResult(output: "{\"items\":[{\"metadata\":{\"uid\":\"rollout\"},\"involvedObject\":{\"uid\":\"api\"},\"reason\":\"Started\",\"message\":\"API moved to release v2\",\"type\":\"Normal\",\"lastTimestamp\":\"" + date + "\"}]}")
            }
            return ContainerCommandResult(output: inventory)
        })
        workspace.discovered = true; workspace.settings.provider = .kubernetes; workspace.settings.kubeContext = "kind-demo"
        workspace.kubeTargets = [ContainerTarget(name: "kind-demo")]
        workspace.inventory.resources = try ContainerDecoding.kubernetes(Data(inventory.utf8))
        let resource = workspace.inventory.resources[0]; workspace.selectedID = resource.id
        await workspace.metrics.sample(workspace)
        guard workspace.metrics.history.points.count == 3 else { throw ContainerHubError("Metrics did not reach charts") }
        let now = Date()
        var samples: [ContainerMetricPoint] = []
        for index in 0..<60 {
            let date = now.addingTimeInterval(Double(index - 59) * 15)
            for (metric, value) in [(ContainerMetric.cpu, 0.25 + Double(index % 12) * 0.08), (.memory, 180_000_000 + Double(index) * 300_000), (.restarts, index < 40 ? 0.0 : 1.0), (.latency, index < 40 ? 45.0 : 160.0), (.errorRate, index < 40 ? 0.0 : 2.5)] {
                samples.append(ContainerMetricPoint(resourceID: resource.id, metric: metric, date: date, value: value))
            }
        }
        workspace.metrics.history.append(samples)
        workspace.inventory.events = [ContainerEvent(id: "deploy", resourceUID: "api", reason: "Deployment restarted", message: "Sample rollout: API moved to release v2", warning: false, timestamp: now.addingTimeInterval(-300))]
        workspace.display = .metrics
        model.runtimeTools(for: project.id).containers = workspace
        model.setSplit(nil)
        model.switchPanel(.containers)
        workspace.metrics.selectedDate = now.addingTimeInterval(-300)
    }
}
#endif
