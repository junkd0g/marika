#if DEBUG
    import AppKit
    import MarikaCore
    import PDFKit
    import SwiftUI

    extension DebugDriver {
        static func runEditorStep(_ step: JSONValue, _ model: AppModel) async throws -> Bool {
            switch step["op"]?.string {
            case "codeOpen":
                guard let meta = model.selectedSession, let project = model.project(for: meta) else { throw DriverError("no project") }
                model.projectTabs[project.id] = .code
                await model.editor(for: project).open(step["path"]?.string ?? "")
            case "codeColors":
                guard let document = model.activeEditor?.selectedDocument, let content = window()?.contentView,
                      let view = textViews(in: content).compactMap({ $0 as? CodeEditingTextView }).first(where: { $0.documentID == document.id }) else { throw DriverError("Code editor not found") }
                let source = document.text as NSString
                let words = step["tokens"]?.array?.compactMap(\.string) ?? ["func", "FetchUser", "invalid user"]
                var colours: [NSColor] = []
                for _ in 0..<50 {
                    colours = words.compactMap { word in
                        let range = source.range(of: word)
                        guard range.location != NSNotFound else { return nil }
                        return (view.textStorage?.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
                    }
                    if Set(colours.map { $0.description }).count >= 3 { break }
                    try await pause(0.05)
                }
                guard Set(colours.map { $0.description }).count >= 3, view.string == document.text, !document.isModified,
                      view.font?.pointSize ?? 0 >= 13, view.defaultParagraphStyle?.lineSpacing ?? 0 >= 3 else { throw DriverError("Editor colour or layout verification failed") }
                log("Distinct syntax colours and readable spacing passed; file unchanged")
            case "codeLayout":
                guard let document = model.activeEditor?.selectedDocument, let content = window()?.contentView,
                      let view = textViews(in: content).compactMap({ $0 as? CodeEditingTextView }).first(where: { $0.documentID == document.id }),
                      let scroll = view.enclosingScrollView, let layout = view.layoutManager, let container = view.textContainer else { throw DriverError("Code editor not found") }
                scroll.needsLayout = true; scroll.layoutSubtreeIfNeeded()
                let wide = view.frame.width > scroll.contentView.bounds.width + 1
                guard wide == (step["wide"]?.bool ?? false) else { throw DriverError("Incorrect horizontal scroll area: viewport=\(scroll.contentView.bounds.width), document=\(view.frame.width)") }
                if wide {
                    scroll.contentView.scroll(to: NSPoint(x: view.frame.width - scroll.contentView.bounds.width, y: 0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    guard scroll.contentView.bounds.minX > 0 else { throw DriverError("Long line cannot scroll horizontally") }
                    scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
                }
                if let wrap = step["wrap"]?.bool {
                    guard container.widthTracksTextView == wrap, scroll.hasHorizontalScroller != wrap else { throw DriverError("Wrap setting did not reach the editor") }
                    let firstLine = (view.string as NSString).lineRange(for: NSRange(location: 0, length: 0))
                    var fragments = 0
                    var rightEdge: CGFloat = 0
                    layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(forCharacterRange: firstLine, actualCharacterRange: nil)) { _, used, _, _, _ in
                        fragments += 1; rightEdge = max(rightEdge, used.maxX)
                    }
                    guard wrap ? fragments > 1 : fragments == 1 else { throw DriverError("Long line wrapping failed: \(fragments) fragments") }
                    if wrap, rightEdge + view.textContainerInset.width > scroll.contentView.bounds.maxX + 1 {
                        throw DriverError("Wrapped text extends beyond the visible edge")
                    }
                }
                log("Native horizontal scrolling and line wrapping checks passed")
            case "editorSettingsTest":
                guard ProcessInfo.processInfo.environment["MARIKA_EDITOR_DEFAULTS_SUITE"] != nil,
                      let document = model.activeEditor?.selectedDocument, let content = window()?.contentView,
                      let view = textViews(in: content).compactMap({ $0 as? CodeEditingTextView }).first(where: { $0.documentID == document.id }),
                      let tabs = marker(in: content, named: "editor-file-tabs"), let toolbar = marker(in: content, named: "editor-toolbar")
                else { throw DriverError("Isolated editor test is not ready") }
                guard tabs.bounds.height <= 35, toolbar.bounds.height <= 35 else { throw DriverError("Editor controls are too tall") }
                let settings = EditorSettings.shared, saved = settings.style, original = view.string
                defer {
                    settings.fontSize = saved.fontSize; settings.theme = saved.theme; settings.tabWidth = saved.tabWidth
                    settings.usesTabs = saved.usesTabs; settings.wrapsLines = saved.wrapsLines; settings.showsIndentGuides = saved.showsIndentGuides
                    document.text = original
                }
                view.undoManager?.removeAllActions()
                view.insertText("\n// preference check", replacementRange: NSRange(location: (original as NSString).length, length: 0))
                try await pause(0.2)
                let selection = view.selectedRange()
                settings.fontSize = 18; settings.theme = .light; settings.tabWidth = 8; settings.usesTabs = true; settings.showsIndentGuides = false
                try await pause(0.3)
                guard view.editorStyle.fontSize == 18, view.font?.pointSize == 18,
                      view.selectedRange() == selection, view.undoManager?.canUndo == true,
                      view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua,
                      view.defaultParagraphStyle?.defaultTabInterval == settings.style.paragraph.defaultTabInterval
                else { throw DriverError("Editor settings did not apply without disturbing the selection or undo") }
                view.undoManager?.undo(); try await pause(0.15)
                guard view.string == original else { throw DriverError("Changing editor settings broke undo") }
                settings.fontSize = 14; settings.theme = .dark; settings.tabWidth = 2; settings.usesTabs = false
                try await pause(0.2)
                let end = (view.string as NSString).length
                view.insertText("\nfunc check() {", replacementRange: NSRange(location: end, length: 0))
                view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                guard view.string.hasSuffix("{\n  ") else { throw DriverError("Newline did not use the chosen indentation width") }
                view.doCommand(by: #selector(NSResponder.insertTab(_:)))
                guard view.string.hasSuffix("{\n    ") else { throw DriverError("Tab did not insert the chosen spaces") }
                settings.usesTabs = true; try await pause(0.2)
                view.doCommand(by: #selector(NSResponder.insertTab(_:)))
                guard view.string.hasSuffix("\t") else { throw DriverError("Tab indentation ignored the setting") }
                let restored = EditorSettings(defaults: UserDefaults(suiteName: ProcessInfo.processInfo.environment["MARIKA_EDITOR_DEFAULTS_SUITE"]!)!)
                guard restored.style == settings.style else { throw DriverError("Editor preferences were not saved") }
                guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window()?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                      let menu = view.menu(for: event), menu.items.contains(where: { $0.title == "Rename Symbol…" }),
                      menu.items.first(where: { $0.title == "Insert Snippet" })?.submenu?.items.count == EditorSnippet.allCases.count
                else { throw DriverError("Editor context actions missing") }
                log("Compact controls, live theme and font, indentation, persisted preferences, context menus, and preserved undo passed")
            case "inlineAssistanceTest":
                try await testInlineAssistance(step, model)
            case "inlineReviewTest":
                try await testInlineReview(step, model)
            case "navigationLinksTest":
                try await testNavigationLinks(step, model)
            case "markdownTest":
                try await testMarkdown(step, model)
            case "editorPopoverShot":
                let name = step["name"]?.string ?? "editor-settings-panel"
                guard let mark = NSApp.windows.compactMap({ $0.contentView.flatMap { marker(in: $0, named: name) } }).first,
                      let view = mark.window?.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw DriverError("Popover not found") }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { throw DriverError("Popover image failed") }
                try data.write(to: URL(fileURLWithPath: step["path"]?.string ?? "popover.png"))
            case "completionTest":
                guard let project = model.selectedProject else { throw DriverError("No project") }
                model.switchPanel(.code)
                let editor = model.editor(for: project)
                await editor.open("Sample.swift")
                editor.focusEditor()
                try await pause(0.3)
                guard let window = window(), let content = window.contentView,
                      let view = textViews(in: content).compactMap({ $0 as? CodeEditingTextView }).first(where: { $0.documentID == editor.selectedDocumentID }) else { throw DriverError("Code editor not mounted") }
                model.completionOverride = "return value"
                defer { model.completionOverride = nil }
                view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
                let original = view.string
                view.onRequestCompletion?()
                for _ in 0..<30 {
                    if view.suggestion == "return value" { break }
                    try await pause(0.05)
                }
                guard view.suggestion == "return value", view.string == original else { throw DriverError("Ghost suggestion changed the document") }
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48) else { throw DriverError("Tab event failed") }
                view.keyDown(with: event)
                try await pause(0.1)
                guard view.string == original + "return value", editor.selectedDocument?.text == view.string else { throw DriverError("Tab did not accept the suggestion") }
                log("Native ghost completion and Tab acceptance passed")
            case "ideTest":
                guard let project = model.selectedProject else { throw DriverError("No project") }
                model.showCode()
                let editor = model.editor(for: project)
                await editor.open("main.go")
                guard let document = editor.selectedDocument else { throw DriverError("Missing Go document") }
                let original = document.text, ide = model.ide(for: project, editor: editor)
                await ide.synchronize(document)
                document.line = 3; document.column = 6
                ide.renameText = "sum"; ide.perform("Rename")
                for _ in 0..<100 { if !ide.pendingEdits.isEmpty { break }; try await pause(0.05) }
                guard !ide.pendingEdits.isEmpty else { throw DriverError("Rename did not produce a preview: " + ide.message) }
                ide.pendingEdits = []
                document.text = original.replacingOccurrences(of: "fmt.Println(value)", with: "fmt.Println(missing)")
                await ide.synchronize(document)
                for _ in 0..<100 { if ide.problemCount > 0 { break }; try await pause(0.05) }
                guard ide.problemCount > 0 else { throw DriverError("Live diagnostic missing") }
                ide.showsPanel = true; ide.panel = "Problems"
                try await pause(0.3)
                if let folder = step["directory"]?.string { try snapshot(to: folder + "/problems.png", title: nil) }
                document.text = original
                ide.discoverTests()
                for _ in 0..<200 { if !ide.testRunning { break }; try await pause(0.05) }
                guard !ide.tests.isEmpty else { throw DriverError("Tests not discovered: " + ide.testOutput) }
                ide.runTest()
                for _ in 0..<200 { if !ide.testRunning { break }; try await pause(0.05) }
                guard ide.testStatuses.values.contains("pass"), !ide.coverage.isEmpty else { throw DriverError("Test results or coverage missing: " + ide.testOutput) }
                try await pause(0.3)
                if let folder = step["directory"]?.string { try snapshot(to: folder + "/tests.png", title: nil) }
                ide.breakpoints["main.go"] = [6]
                ide.launchDebugger()
                for _ in 0..<400 { if ide.debug.isPaused || ide.debug.error != nil { break }; try await pause(0.05) }
                guard ide.debug.isPaused else { throw DriverError("Debugger did not pause: " + (ide.debug.error ?? ide.message)) }
                await ide.debug.evaluate("value")
                guard ide.debug.watches["value"] == "5" else { throw DriverError("Debugger value unavailable") }
                try await pause(0.3)
                if let folder = step["directory"]?.string { try snapshot(to: folder + "/debugger.png", title: nil) }
                await ide.debug.stop()
                log("Live diagnostics, rename preview, test explorer, coverage, breakpoint and watch passed")
            case "editorMechanicsTest":
                guard let project = model.selectedProject else { throw DriverError("No project") }
                model.showCode(); let editor = model.editor(for: project)
                await editor.open("main.go"); try await pause(0.2)
                guard let document = editor.selectedDocument, let content = window()?.contentView,
                      let view = textViews(in: content).compactMap({ $0 as? CodeEditingTextView }).first(where: { $0.documentID == document.id }) else { throw DriverError("Code view not found") }
                let original = view.string, source = original as NSString
                let first = source.range(of: "func"), second = source.range(of: "func", range: NSRange(location: NSMaxRange(first), length: source.length - NSMaxRange(first)))
                view.undoManager?.removeAllActions()
                view.selectedRanges = [NSValue(range: first), NSValue(range: second)]
                guard view.selectedRanges.count == 2 else { throw DriverError("Multiple selections unavailable") }
                view.insertText("function", replacementRange: first); try await pause(0.1)
                guard view.string.components(separatedBy: "function").count == 3, document.text == view.string else { throw DriverError("Multi-cursor edit failed") }
                view.undoManager?.undo(); try await pause(0.1)
                guard view.string == original, document.text == original else { throw DriverError("Multi-cursor undo failed") }
                document.line = 4; document.column = 1
                let ide = model.ide(for: project, editor: editor)
                let height = view.layoutManager?.usedRect(for: view.textContainer!).height ?? 0
                ide.perform("Fold")
                for _ in 0..<50 { if !document.foldedRanges.isEmpty { break }; try await pause(0.05) }
                try await pause(0.2)
                view.layoutManager?.ensureLayout(for: view.textContainer!)
                guard !document.foldedRanges.isEmpty, view.string == original,
                      (view.layoutManager?.usedRect(for: view.textContainer!).height ?? height) < height else { throw DriverError("Code folding did not collapse the block") }
                document.foldedRanges = []
                if let folder = step["directory"]?.string {
                    model.projectSettingsID = project.id; try await pause(0.4)
                    try snapshot(to: folder + "/settings.png", title: nil, sheet: true)
                }
                log("Native multi-cursor editing, undo, and non-destructive folding passed")
            case "codeQuickOpen":
                model.showCode(quickOpen: true)
            case "codeSearch":
                let target = window()?.attachedSheet ?? window()
                guard let view = target?.contentView,
                      let field = textField(in: view, placeholder: step["navigator"]?.bool == true ? "Find files…" : "Go to file…")
                else {
                    log("file search missing: window=\(target?.title ?? "none"), frame=\(target?.frame ?? .zero), navigator=\(model.activeEditor?.showsNavigator == true)")
                    try? await run(["op": "uiState"], model)
                    throw DriverError("file search field not found")
                }
                target?.makeFirstResponder(field)
                if let input = field.currentEditor() as? NSTextView {
                    input.insertText(step["text"]?.string ?? "", replacementRange: NSRange(location: 0, length: (input.string as NSString).length))
                } else {
                    field.stringValue = step["text"]?.string ?? ""
                    field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                    field.sendAction(field.action, to: field.target)
                }
            case "codeNavigator":
                model.showCode(focusFiles: true)
                if let path = step["path"]?.string { model.activeEditor?.navigatorSelection = path }
            case "codeClickRow":
                guard let editor = model.activeEditor, let window = window(), let view = window.contentView,
                      let path = step["path"]?.string,
                      let row = editor.visibleEntries.firstIndex(where: { $0.id == path }),
                      let table = tables(in: view).max(by: {
                          $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
                      }), row < table.numberOfRows
                else { throw DriverError("file row not found") }
                let rect = table.convert(table.rect(ofRow: row), to: nil)
                let point = NSPoint(x: rect.minX + min(130, rect.width / 2), y: rect.midY)
                guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                      context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
                      let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                      timestamp: ProcessInfo.processInfo.systemUptime + 0.02, windowNumber: window.windowNumber,
                      context: nil, eventNumber: 2, clickCount: 1, pressure: 0)
                else { throw DriverError("could not create file click") }
                NSApp.postEvent(up, atStart: false)
                window.sendEvent(down)
            case "codeAdjacent":
                model.activeEditor?.selectAdjacentDocument(step["offset"]?.int ?? 1)
            case "codePDFState":
                guard let view = window()?.contentView, let pdf = pdfView(in: view),
                      let document = pdf.document, document.pageCount > 0,
                      pdf.bounds.width > 0, pdf.bounds.height > 0,
                      let page = document.page(at: 0),
                      page.string?.contains(step["contains"]?.string ?? "") == true
                else { throw DriverError("PDF content is not loaded in the preview") }
                log("PDF preview loaded: pages=\(document.pageCount) scale=\(pdf.scaleFactor)")
            case "codeInsert":
                guard let document = model.activeEditor?.selectedDocument,
                    let field = window()?.firstResponder as? CodeEditingTextView, field.documentID == document.id
                else { throw DriverError("code editor is not focused") }
                let range = step["replaceAll"]?.bool == true
                    ? NSRange(location: 0, length: (field.string as NSString).length) : field.selectedRange()
                field.insertText(step["text"]?.string ?? "", replacementRange: range)
            case "codeSave":
                guard let editor = model.activeEditor, let document = editor.selectedDocument else { throw DriverError("no code document") }
                let saved = await editor.save(document)
                if !saved, step["allowFailure"]?.bool != true { throw DriverError(editor.errorMessage ?? "save failed") }
            case "codeRefresh":
                await model.activeEditor?.refresh()
            case "codeUndo":
                guard let field = window()?.firstResponder as? NSTextView, !(field is PromptTextView) else { throw DriverError("editor not focused") }
                field.undoManager?.undo()
            case "codeFind":
                model.activeEditor?.findRequest += 1
            case "codeDiskEdit":
                guard let editor = model.activeEditor, let document = editor.selectedDocument else { throw DriverError("no code document") }
                try Data((step["text"]?.string ?? "").utf8).write(to: editor.root.appendingPathComponent(document.path))
            case "codeState":
                guard let editor = model.activeEditor else { throw DriverError("no code editor") }
                let state: [String: Any] = [
                    "path": editor.selectedDocument?.path ?? "",
                    "text": editor.selectedDocument?.text ?? "",
                    "modified": editor.selectedDocument?.isModified ?? false,
                    "recovered": editor.selectedDocument?.isRecoveredDraft ?? false,
                    "conflict": editor.selectedDocument?.changedOnDisk ?? false,
                    "documents": editor.documents.map(\.path),
                    "preview": editor.selectedDocument?.preview?.url.lastPathComponent ?? "",
                    "navigator": editor.navigatorSelection ?? "",
                    "navigatorVisible": editor.showsNavigator,
                    "navigatorQuery": editor.navigatorQuery,
                    "pendingTrash": editor.pendingTrashPath ?? "",
                    "canGoBack": editor.canGoBack,
                    "canGoForward": editor.canGoForward,
                    "recentFiles": editor.recentFilePaths,
                    "quickOpen": editor.showsQuickOpen,
                    "focusRequested": editor.focusEditorOnSelection,
                    "error": editor.errorMessage ?? "",
                    "responder": window()?.firstResponder.map { String(describing: type(of: $0)) } ?? "none",
                    "focusedDocument": (window()?.firstResponder as? CodeEditingTextView)?.documentID == editor.selectedDocumentID,
                ]
                log("code " + String(decoding: try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), as: UTF8.self))
            default: return false
            }
            return true
        }
    }
#endif
