import AppKit
import MarikaCore
import Observation
import SwiftUI

@MainActor @Observable final class CodeAssistPresentation {
    enum Kind { case completions, documentation, signature, diagnostic, fixes }
    var kind: Kind = .completions
    var completions: [LanguageCompletion] = []
    var fixes: [EditorQuickFix] = []
    var selected = 0
    var title = ""
    var text = ""
    var detail = ""
    var signature: LanguageSignature?
    var loading = false
}

/// Child panels keep the insertion point in the editor while supporting mouse interaction.
@MainActor private final class CodeAssistPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        hidesOnDeactivate = true; isReleasedWhenClosed = false
        animationBehavior = .none
    }
}

@MainActor final class InlineCodeAssistant {
    weak var view: CodeEditingTextView?
    let ide: IDEWorkspace
    let document: CodeDocument
    let list = CodeAssistPresentation()
    let info = CodeAssistPresentation()
    private var listPanel: CodeAssistPanel?
    private var infoPanel: CodeAssistPanel?
    private var navigationPanel: CodeAssistPanel?
    let navigation = CodeNavigationPresentation()
    private var navigationTask: Task<Void, Never>?
    var isNavigationVisible: Bool { navigationPanel?.isVisible == true }
    private var completionTask: Task<Void, Never>?
    private var informationTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var generation = 0
    private var infoGeneration = 0
    private var hoverOffset: Int?
    private var anchor = NSRange(location: 0, length: 0)
    private var listSource = ""
    private var applying = false
    private var completionPending = false
    private var signatureActive = false
    private var scrollObserver: NSObjectProtocol?
    var isCompletionVisible: Bool { listPanel?.isVisible == true && list.kind == .completions }
    var isCompletionActive: Bool { completionPending || isCompletionVisible }
    var isInformationVisible: Bool { infoPanel?.isVisible == true }

    init(view: CodeEditingTextView, ide: IDEWorkspace, document: CodeDocument) {
        self.view = view; self.ide = ide; self.document = document
        view.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: view.enclosingScrollView?.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
    }
    deinit {
        completionTask?.cancel(); informationTask?.cancel(); detailTask?.cancel(); actionTask?.cancel(); navigationTask?.cancel()
    }

    func dismiss() {
        generation += 1; infoGeneration += 1
        completionTask?.cancel(); informationTask?.cancel(); detailTask?.cancel()
        navigationTask?.cancel(); navigationPanel?.orderOut(nil)
        listPanel?.orderOut(nil); infoPanel?.orderOut(nil)
        hoverOffset = nil
        completionPending = false
        signatureActive = false
    }
    func shutdown() {
        dismiss(); actionTask?.cancel()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver); self.scrollObserver = nil }
        if let listPanel { listPanel.parent?.removeChildWindow(listPanel) }
        if let infoPanel { infoPanel.parent?.removeChildWindow(infoPanel) }
        if let navigationPanel { navigationPanel.parent?.removeChildWindow(navigationPanel) }
        navigationPanel?.close(); navigationPanel = nil
        listPanel?.close(); infoPanel?.close(); listPanel = nil; infoPanel = nil
    }
    func setActive(_ active: Bool) { if !active { dismiss() } }

    func textChanged() {
        guard !applying, let view else { return }
        let updateSignature = signatureActive
        dismiss()
        guard view.editorActive, view.selectedRanges.count == 1, view.selectedRange().length == 0,
              view.window?.firstResponder === view, ide.supportsAssistance(for: document) else { return }
        let source = view.string as NSString, offset = view.selectedRange().location
        guard offset > 0, offset <= source.length else { return }
        let previous = source.substring(with: NSRange(location: offset - 1, length: 1))
        if previous == "(" || previous == "," || updateSignature { requestSignature(delay: true) }
        let word = LanguageAssistance.wordRange(in: view.string, at: offset)
        if previous == "." || (offset - word.location >= 2 && previous.rangeOfCharacter(from: .alphanumerics.union(CharacterSet(charactersIn: "_$"))) != nil) {
            requestCompletions(manual: false)
        }
    }

    func selectionChanged() {
        guard !applying, let view else { return }
        if listPanel?.isVisible == true, view.string == listSource, view.selectedRange() != anchor { dismiss() }
    }

    @discardableResult
    func keyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 111 {
            requestNavigation(references: flags == .shift, openDirectly: flags.isEmpty); return true
        }
        if isNavigationVisible {
            if event.keyCode == 53 { dismiss(); return true }
            if flags.isEmpty, event.keyCode == 125 || event.keyCode == 126, !navigation.locations.isEmpty {
                navigation.selected = (navigation.selected + (event.keyCode == 125 ? 1 : navigation.locations.count - 1)) % navigation.locations.count
                return true
            }
            if event.keyCode == 36, flags.isEmpty { openNavigation(navigation.selected); return true }
        }
        if event.keyCode == 49, flags == .control, ide.supportsAssistance(for: document) { requestCompletions(manual: true); return true }
        if event.keyCode == 49, flags == [.control, .shift] { requestSignature(delay: false); return true }
        if event.keyCode == 36, flags == .option { requestFixes(); return true }
        if event.keyCode == 53, isCompletionActive || infoPanel?.isVisible == true {
            dismiss(); return true
        }
        guard listPanel?.isVisible == true, !list.loading, flags.isEmpty else { return false }
        let count = list.kind == .completions ? list.completions.count : list.fixes.count
        if event.keyCode == 125 || event.keyCode == 126, count > 0 {
            list.selected = (list.selected + (event.keyCode == 125 ? 1 : count - 1)) % count
            updateCompletionDetail(); return true
        }
        if event.keyCode == 48 || event.keyCode == 36, count > 0 { choose(list.selected); return true }
        return false
    }

    func requestNavigation(at offset: Int? = nil, references: Bool = false, openDirectly: Bool = false) {
        guard let view, view.editorActive else { return }
        dismiss()
        let request = generation, text = view.string
        let range = NSRange(location: offset ?? view.selectedRange().location, length: 0)
        navigationTask = Task { [weak self, weak view] in
            guard let self else { return }
            do {
                let locations = try await ide.locations(in: document, text: text, offset: range.location, references: references)
                guard !Task.isCancelled, generation == request, let view, view.editorActive, view.string == text else { return }
                if openDirectly, locations.count == 1 { await ide.open(locations[0]); return }
                guard !locations.isEmpty else { showMessage(references ? "No references found in this project." : "No definition found in this project.", at: range); return }
                navigation.locations = locations; navigation.selected = 0; navigation.title = references ? "References" : "Definition"
                let panel = navigationPanel ?? CodeAssistPanel(); navigationPanel = panel
                panel.contentView = NSHostingView(rootView: CodeNavigationPreview(state: navigation,
                    select: { [weak self] in self?.navigation.selected = $0 }, open: { [weak self] in self?.openNavigation($0) }, close: { [weak self] in self?.dismiss() }))
                show(panel, size: NSSize(width: 560, height: 270), range: range)
            } catch {
                if !Task.isCancelled, generation == request { showMessage(error.localizedDescription, at: range) }
            }
        }
    }

    private func openNavigation(_ index: Int) {
        guard navigation.locations.indices.contains(index) else { return }
        let location = navigation.locations[index]
        dismiss()
        actionTask = Task { [weak self] in await self?.ide.open(location) }
    }

    func requestCompletions(manual: Bool) {
        guard let view, view.editorActive, view.selectedRanges.count == 1, view.selectedRange().length == 0,
              ide.supportsAssistance(for: document) else { return }
        generation += 1; let request = generation
        completionPending = true
        completionTask?.cancel(); detailTask?.cancel(); infoPanel?.orderOut(nil)
        let source = view.string, selection = view.selectedRange()
        completionTask = Task { [weak self, weak view] in
            guard let self else { return }
            defer { if generation == request { completionPending = false } }
            do {
                if !manual { try await Task.sleep(for: .milliseconds(160)) }
                try Task.checkCancellation()
                let items = try await ide.completions(in: document, text: source, offset: selection.location)
                guard generation == request, let view, view.editorActive, view.string == source,
                      view.selectedRange() == selection else { return }
                guard !items.isEmpty else { listPanel?.orderOut(nil); return }
                view.onDismissAgentSuggestion?()
                view.suggestion = ""
                list.kind = .completions; list.loading = false; list.completions = items
                list.selected = items.firstIndex(where: { $0.item["preselect"]?.bool == true }) ?? 0
                listSource = source; anchor = selection; list.title = "Suggestions"
                updateCompletionDetail()
                showList(at: selection)
            } catch {
                if manual, !Task.isCancelled, generation == request { showMessage(error.localizedDescription, at: selection) }
            }
        }
    }

    private func updateCompletionDetail() {
        guard list.kind == .completions, list.completions.indices.contains(list.selected) else { return }
        detailTask?.cancel()
        let item = list.completions[list.selected]
        list.detail = item.detail
        let documentation = LanguageAssistance.documentation(item.item["documentation"])
        if !documentation.isEmpty { list.detail = documentation; return }
        detailTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            if let resolved = try? await ide.resolve(item, in: document), !Task.isCancelled,
               list.completions.indices.contains(list.selected), list.completions[list.selected].id == item.id {
                let documentation = LanguageAssistance.documentation(resolved["documentation"])
                list.detail = documentation.isEmpty ? resolved["detail"]?.string ?? item.detail : documentation
            }
        }
    }

    func mouseMoved(at point: NSPoint) {
        guard let view, view.editorActive, listPanel?.isVisible != true, !applying else { return }
        let offset = view.characterIndexForInsertion(at: point)
        let word = LanguageAssistance.wordRange(in: view.string, at: offset)
        if word.length > 0, let window = view.window {
            let screen = view.firstRect(forCharacterRange: word, actualRange: nil)
            let rect = view.convert(window.convertFromScreen(screen), from: nil).insetBy(dx: -4, dy: -3)
            guard rect.contains(point) else { mouseExited(); return }
        } else { mouseExited(); return }
        guard offset != hoverOffset else { return }
        hoverOffset = offset
        requestHover(at: offset, delay: true)
    }
    func mouseExited() {
        informationTask?.cancel()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self else { return }
            if infoPanel?.frame.contains(NSEvent.mouseLocation) != true { infoPanel?.orderOut(nil); hoverOffset = nil }
        }
    }

    func requestHover(at offset: Int, delay: Bool = false) {
        guard let view, view.editorActive, ide.supportsAssistance(for: document) else { return }
        infoGeneration += 1; let request = infoGeneration
        informationTask?.cancel(); infoPanel?.orderOut(nil)
        let source = view.string
        let word = LanguageAssistance.wordRange(in: source, at: offset)
        informationTask = Task { [weak self] in
            guard let self else { return }
            do {
                if delay { try await Task.sleep(for: .milliseconds(500)) }
                try Task.checkCancellation()
                guard infoGeneration == request, view.editorActive, view.string == source else { return }
                let diagnostics = diagnostics(at: offset, source: source)
                if let diagnostic = diagnostics.first {
                    info.kind = .diagnostic; info.title = diagnostic["severity"]?.int == 1 ? "Error" : "Warning"
                    info.text = diagnostics.compactMap { $0["message"]?.string }.joined(separator: "\n\n")
                    anchor = word; showInfo(at: word); return
                }
                guard word.length > 0, let hover = try await ide.hover(in: document, text: source, offset: offset),
                      infoGeneration == request, view.editorActive, view.string == source else { return }
                info.kind = .documentation; info.title = "Documentation"; info.text = hover.text
                showInfo(at: hover.range)
            } catch { }
        }
    }

    func requestSignature(delay: Bool) {
        guard let view, ide.supportsAssistance(for: document) else { return }
        signatureActive = true
        infoGeneration += 1; let request = infoGeneration
        informationTask?.cancel()
        let source = view.string, selection = view.selectedRange()
        informationTask = Task { [weak self] in
            guard let self else { return }
            do {
                if delay { try await Task.sleep(for: .milliseconds(180)) }
                let value = try await ide.signature(in: document, text: source, offset: selection.location)
                guard infoGeneration == request, view.editorActive,
                      view.string == source, view.selectedRange() == selection else { return }
                guard let value else { signatureActive = false; infoPanel?.orderOut(nil); return }
                info.kind = .signature; info.title = "Function signature"; info.signature = value
                info.text = value.documentation; showInfo(at: selection)
            } catch { }
        }
    }

    func requestFixes(at offset: Int? = nil) {
        guard let view, view.editorActive, ide.supportsAssistance(for: document) else { return }
        dismiss()
        let source = view.string, location = min(offset ?? view.selectedRange().location, (source as NSString).length)
        let relevant = diagnostics(at: location, source: source)
        var range = NSRange(location: location, length: 0)
        if let first = relevant.first, let a = first["range"]?["start"], let b = first["range"]?["end"],
           let lower = try? SourcePosition.offset(a, in: source), let upper = try? SourcePosition.offset(b, in: source), upper >= lower {
            range = NSRange(location: lower, length: upper - lower)
        }
        anchor = range; listSource = source
        list.kind = .fixes; list.title = "Quick fixes"; list.selected = 0; list.fixes = []; list.loading = true
        list.text = relevant.compactMap { $0["message"]?.string }.joined(separator: "\n\n")
        showList(at: range)
        let request = generation
        completionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fixes = try await ide.quickFixes(in: document, text: source, range: range)
                guard !Task.isCancelled, generation == request, view.string == source else { return }
                list.fixes = fixes; list.loading = false; showList(at: range)
            } catch {
                guard !Task.isCancelled, generation == request else { return }
                list.loading = false; list.text = error.localizedDescription; showList(at: range)
            }
        }
    }

    func choose(_ index: Int) {
        guard let view, !applying else { return }
        if list.kind == .completions {
            guard list.completions.indices.contains(index) else { return }
            let item = list.completions[index]
            dismiss()
            actionTask = Task { [weak self, weak view] in
                guard let self, let view else { return }
                do {
                    let resolved = try await ide.resolve(item, in: document)
                    try Task.checkCancellation()
                    guard view.editorActive, view.selectedRange().location == item.offset else { return }
                    let result = try item.applying(resolved: resolved, to: view.string)
                    applying = true
                    view.applyAssistanceText(result.text, selection: result.selection, action: "Complete code")
                    applying = false
                } catch { showMessage(error.localizedDescription, at: view.selectedRange()) }
            }
        } else if list.kind == .fixes {
            guard list.fixes.indices.contains(index) else { return }
            let fix = list.fixes[index]
            dismiss()
            actionTask = Task { [weak self, weak view] in
                guard let self, let view else { return }
                do {
                    try await ide.apply(fix, in: document) { updated in
                        self.applying = true
                        view.applyAssistanceText(updated, selection: NSRange(location: min(view.selectedRange().location, (updated as NSString).length), length: 0), action: "Apply quick fix")
                        self.applying = false
                    }
                } catch { showMessage(error.localizedDescription, at: view.selectedRange()) }
            }
        }
    }

    private func diagnostics(at offset: Int, source: String) -> [JSONValue] {
        (ide.diagnostics[document.path] ?? []).filter {
            guard let a = $0["range"]?["start"], let b = $0["range"]?["end"],
                  let lower = try? SourcePosition.offset(a, in: source), let upper = try? SourcePosition.offset(b, in: source) else { return false }
            return lower <= offset && offset <= max(lower + 1, upper)
        }
    }
    private func showMessage(_ text: String, at range: NSRange) {
        info.kind = .documentation; info.title = "Code assistance"; info.text = text; showInfo(at: range)
    }
    private func showList(at range: NSRange) {
        let panel = listPanel ?? CodeAssistPanel(); listPanel = panel
        let count = list.kind == .completions ? list.completions.count : list.fixes.count
        let height: CGFloat = list.kind == .completions ? CGFloat(min(7, count)) * 32 + 88 : CGFloat(min(6, max(1, count))) * 34 + (list.text.isEmpty ? 64 : 128)
        panel.contentView = NSHostingView(rootView: CodeAssistList(state: list, choose: { [weak self] in self?.choose($0) }))
        show(panel, size: NSSize(width: 400, height: height), range: range)
    }
    private func showInfo(at range: NSRange) {
        let panel = infoPanel ?? CodeAssistPanel(); infoPanel = panel
        let blocks = MarkdownParser.parse(info.text)
        let textHeight = blocks.reduce(CGFloat(0)) { height, block in
            switch block {
            case .code(_, let code): height + CGFloat(code.components(separatedBy: "\n").count) * 16 + 24
            case .paragraph(let text), .quote(let text), .heading(_, let text): height + CGFloat(max(1, (text.count + 59) / 60)) * 17 + 9
            case .list(let items): height + CGFloat(items.count) * 22
            default: height + 12
            }
        }
        let height = info.kind == .signature ? 155 : min(310, max(120, textHeight + 58 + (info.kind == .diagnostic ? 34 : 0)))
        panel.contentView = NSHostingView(rootView: CodeAssistInformation(state: info, quickFix: { [weak self] in self?.requestFixes(at: range.location) }, close: { [weak self] in self?.infoPanel?.orderOut(nil) }))
        show(panel, size: NSSize(width: 440, height: height), range: range, above: info.kind == .signature)
    }
    private func show(_ panel: CodeAssistPanel, size: NSSize, range: NSRange, above: Bool = false) {
        guard let view, view.editorActive, let window = view.window else { return }
        let caret = view.firstRect(forCharacterRange: range, actualRange: nil)
        let visible = (window.screen?.visibleFrame ?? window.frame).intersection(window.frame).insetBy(dx: 8, dy: 8)
        var origin = NSPoint(x: min(max(caret.minX, visible.minX), visible.maxX - size.width), y: caret.minY - size.height - 5)
        if above, caret.maxY + size.height + 5 < visible.maxY { origin.y = caret.maxY + 5 }
        if origin.y < visible.minY { origin.y = min(visible.maxY - size.height, caret.maxY + 5) }
        panel.appearance = view.effectiveAppearance
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }
}

private struct CodeAssistList: View {
    @Bindable var state: CodeAssistPresentation
    var choose: (Int) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: state.kind == .completions ? "text.cursor" : "lightbulb")
                Text(state.title).fontWeight(.medium)
                Spacer()
                if state.loading { ProgressView().controlSize(.mini) }
                else { Text("\(state.kind == .completions ? state.completions.count : state.fixes.count)").foregroundStyle(.secondary) }
            }.font(.system(size: 11)).padding(.horizontal, 12).frame(height: 29)
            Divider()
            if state.kind == .fixes, !state.text.isEmpty {
                Text(state.text).font(.system(size: 11)).lineLimit(3).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if state.kind == .completions {
                            ForEach(Array(state.completions.enumerated()), id: \.element.id) { index, item in
                                row(index, symbol: symbol(item.kind), title: item.label, detail: item.detail).id(index)
                            }
                        } else {
                            ForEach(Array(state.fixes.enumerated()), id: \.element.id) { index, item in
                                row(index, symbol: "wand.and.stars", title: item.title, detail: "").id(index)
                            }
                            if state.fixes.isEmpty { Text(state.loading ? "Finding fixes…" : "No quick fixes at this position").font(.system(size: 12)).foregroundStyle(.secondary).padding(12) }
                        }
                    }
                }.onChange(of: state.selected) { _, index in proxy.scrollTo(index) }
            }
            if state.kind == .completions {
                Divider()
                Text(state.detail.replacingOccurrences(of: "```", with: "")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .lineLimit(2).frame(maxWidth: .infinity, minHeight: 27, alignment: .leading).padding(.horizontal, 10)
            }
            Divider()
            Text(state.kind == .completions ? "↑↓ choose   Tab or Return to insert   Esc dismiss" : "↑↓ choose   Return to apply   Esc dismiss")
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 24)
        }
        .background(Theme.panel).foregroundStyle(.primary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
        #if DEBUG
        .background(DebugViewMarker(name: "code-assist-list"))
        #endif
    }
    private func row(_ index: Int, symbol: String, title: String, detail: String) -> some View {
        Button { choose(index) } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 16)
                Text(title).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                Spacer(minLength: 3)
                if !detail.isEmpty { Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 120) }
            }.padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
                .background(state.selected == index ? Color.accentColor.opacity(0.16) : .clear)
        }.buttonStyle(.plain)
        #if DEBUG
        .background(DebugViewMarker(name: "code-assist-choice-\(index)"))
        #endif
    }
    private func symbol(_ kind: Int) -> String {
        switch kind { case 2, 3, 4: "function"; case 7, 8, 22: "cube"; case 9: "shippingbox"; case 14: "key"; case 5, 6, 10: "v.circle"; default: "textformat" }
    }
}

private struct CodeAssistInformation: View {
    @Bindable var state: CodeAssistPresentation
    var quickFix: () -> Void
    var close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(state.title, systemImage: state.kind == .diagnostic ? "exclamationmark.triangle" : "info.circle")
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss code information")
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(11)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    if state.kind == .signature, let signature = state.signature {
                        Text(signature.label).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        if let parameter = signature.parameter { Text(parameter).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Color.accentColor) }
                    }
                    if state.kind == .diagnostic { Text(state.text).font(.system(size: 12)).textSelection(.enabled) }
                    else { documentation }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            if state.kind == .diagnostic {
                Divider()
                Button(action: quickFix) { HStack { Label("Show quick fixes", systemImage: "lightbulb"); Spacer(); Text("⌥↩").foregroundStyle(.secondary) } }
                    .buttonStyle(.plain).font(.system(size: 11)).padding(11)
            }
        }.background(Theme.panel).foregroundStyle(.primary)
            .clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
            .environment(\.openURL, OpenURLAction { ["https", "http"].contains($0.scheme?.lowercased() ?? "") ? .systemAction : .discarded })
            #if DEBUG
            .background(DebugViewMarker(name: "code-assist-information"))
            #endif
    }
    private var documentation: some View {
        ForEach(Array(MarkdownParser.parse(String(state.text.prefix(12_000))).prefix(30).enumerated()), id: \.offset) { _, block in
            switch block {
            case .code(_, let code): Text(code).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Theme.surface, in: RoundedRectangle(cornerRadius: 5))
            case .paragraph(let text), .quote(let text): InlineText(text).font(.system(size: 12)).textSelection(.enabled)
            case .heading(_, let text): InlineText(text).font(.system(size: 12, weight: .semibold))
            case .list(let items): ForEach(Array(items.enumerated()), id: \.offset) { _, item in InlineText("• " + item.text).font(.system(size: 12)) }
            default: EmptyView()
            }
        }
    }
}
