import AppKit
import MarikaCore
import UniformTypeIdentifiers

extension DesignCanvasModel {
    // MARK: Chat and export

    var hasDesignReference: Bool {
        doc.nodes.contains { selection.isEmpty ? !$0.isHidden : selection.contains($0.id) }
    }

    func useInChat() {
        guard !preparingReference, let app else { return }
        preparingReference = true
        let ids = selection
        Task {
            defer { preparingReference = false }
            do { try await app.useDesignElementsInChat(projectID: projectID, selection: ids) }
            catch { report("Couldn't use design in chat", error) }
        }
    }

    private func report(_ title: String, _ error: Error) {
        errorTitle = title; errorMessage = error.localizedDescription
    }

    func copyImage() {
        do {
            let png = try DesignRenderer.png(document: doc, selection: selection)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(png, forType: .png)
        } catch { report("Couldn't copy design", error) }
    }

    func export() {
        do {
            let png = try DesignRenderer.png(document: doc, selection: selection)
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
                throw DesignToolError("Open a project window to export.")
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            let project = app?.project(id: projectID)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.directoryURL = project?.url
            let name = String((project?.name ?? "Marika").map { "/\\:".contains($0) ? "-" : $0 }.prefix(90))
            panel.nameFieldStringValue = "\(name) design.png"
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                Task {
                    do { try await Task.detached { try png.write(to: url, options: .atomic) }.value }
                    catch { self?.report("Couldn't export design", error) }
                }
            }
        } catch { report("Couldn't export design", error) }
    }
    func exportSVG() {
        do {
            let data = Data(try DesignSVG.render(doc, selection: selection).utf8)
            let panel = NSSavePanel(); panel.allowedContentTypes = [.svg]; panel.canCreateDirectories = true
            panel.nameFieldStringValue = "Design.svg"
            if let project = app?.project(id: projectID) { panel.directoryURL = project.url }
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                do { try data.write(to: url, options: .atomic) } catch { self?.report("Couldn't export SVG", error) }
            }
        } catch { report("Couldn't export SVG", error) }
    }
}
