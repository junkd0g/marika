import AppKit
import MarikaCore
import SwiftUI

struct CodeTextView: NSViewRepresentable {
    @Bindable var document: CodeDocument
    var isActive: Bool
    var findRequest: Int
    var focusRequest: Int
    var shouldFocus: Bool
    var style = EditorStyle()
    var onEditorAction: ((String) -> Void)?
    var ide: IDEWorkspace?
    var diagnostics: [JSONValue] = []
    var breakpoints: Set<Int> = []
    var coverage: [Int: Bool] = [:]
    var toggleBreakpoint: ((Int) -> Void)?
    var automaticCompletions = false
    var requestCompletion: ((String, Int) async throws -> String)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CodeEditingTextView(frame: .zero)
        textView.documentID = document.id
        textView.editorStyle = style
        textView.onEditorAction = onEditorAction
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.font = style.font
        textView.textColor = CodePalette.foreground
        textView.insertionPointColor = CodePalette.foreground
        textView.backgroundColor = CodePalette.background
        textView.selectedTextAttributes = [.backgroundColor: CodePalette.selection, .foregroundColor: CodePalette.foreground]
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = style.wrapsLines
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.delegate = context.coordinator
        textView.layoutManager?.delegate = context.coordinator
        textView.layoutManager?.backgroundLayoutEnabled = false
        textView.onRequestCompletion = { [weak coordinator = context.coordinator] in coordinator?.suggest(delay: false) }
        textView.onAppearanceChange = { [weak coordinator = context.coordinator] in coordinator?.highlight() }
        textView.setAccessibilityLabel("Code editor for \(document.name)")
        textView.defaultParagraphStyle = style.paragraph

        let scrollView = CodeScrollView()
        scrollView.appearance = style.theme.appearance
        scrollView.wrapsLines = style.wrapsLines
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !style.wrapsLines
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        let ruler = CodeLineRuler(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.configureAssistance()
        textView.string = document.text
        ruler.updateLines()
        context.coordinator.highlight()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        return scrollView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: proposal.height ?? 400)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let previousStyle = coordinator.parent.style
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        coordinator.configureAssistance()
        (textView as? CodeEditingTextView)?.editorStyle = style
        (textView as? CodeEditingTextView)?.onEditorAction = onEditorAction
        if previousStyle != style {
            scrollView.appearance = style.theme.appearance
            textView.defaultParagraphStyle = style.paragraph
            coordinator.highlight()
        }
        if let codeScroll = scrollView as? CodeScrollView, codeScroll.wrapsLines != style.wrapsLines {
            codeScroll.wrapsLines = style.wrapsLines
            codeScroll.hasHorizontalScroller = !style.wrapsLines
            textView.textContainer?.widthTracksTextView = style.wrapsLines
            if style.wrapsLines { codeScroll.contentView.scroll(to: NSPoint(x: 0, y: codeScroll.contentView.bounds.minY)) }
            codeScroll.needsLayout = true
        }
        (textView as? CodeEditingTextView)?.foldedRanges = document.foldedRanges
        coordinator.ruler?.breakpoints = breakpoints
        coordinator.ruler?.coverage = coverage
        coordinator.ruler?.toggleBreakpoint = toggleBreakpoint
        coordinator.ruler?.diagnosticLines = Set(diagnostics.compactMap { $0["range"]?["start"]?["line"]?.int }.map { $0 + 1 })
        coordinator.ruler?.folds = document.foldedRanges
        coordinator.ruler?.needsDisplay = true
        if coordinator.lastDiagnostics != diagnostics || coordinator.folds != document.foldedRanges {
            coordinator.lastDiagnostics = diagnostics
            coordinator.folds = document.foldedRanges
            textView.layoutManager?.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: (textView.string as NSString).length), changeInLength: 0, actualCharacterRange: nil)
            coordinator.highlight()
        }
        (textView as? CodeEditingTextView)?.editorActive = isActive
        if !isActive { coordinator.clearSuggestion() }
        if coordinator.lastCompletionRequest != document.completionRequest {
            coordinator.lastCompletionRequest = document.completionRequest
            if isActive { coordinator.suggest(delay: false) }
        }
        if coordinator.lastNavigationRequest != document.navigationRequest {
            coordinator.lastNavigationRequest = document.navigationRequest
            if isActive { coordinator.assistance?.requestNavigation(references: document.navigationAction == "References", openDirectly: document.navigationAction == "Definition") }
        }
        if !isActive, let window = textView.window, window.firstResponder === textView {
            window.makeFirstResponder(nil)
        }
        if textView.string != document.text {
            coordinator.clearSuggestion()
            let selection = textView.selectedRange()
            textView.string = document.text
            textView.undoManager?.removeAllActions()
            coordinator.ruler?.updateLines()
            textView.setSelectedRange(NSRange(location: min(selection.location, (document.text as NSString).length), length: 0))
            coordinator.highlight()
        }
        if isActive, shouldFocus, !coordinator.wasActive || coordinator.lastFocusRequest != focusRequest {
            (textView as? CodeEditingTextView)?.requestEditorFocus()
        } else if !isActive || !shouldFocus {
            (textView as? CodeEditingTextView)?.cancelEditorFocus()
        }
        coordinator.wasActive = isActive
        coordinator.lastFocusRequest = focusRequest
        if isActive, coordinator.lastSelectionRequest != document.selectionRequest {
            coordinator.lastSelectionRequest = document.selectionRequest
            let text = document.text as NSString
            var start = 0
            for _ in 1..<max(1, document.line) {
                guard start < text.length else { break }
                let next = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
                guard next > start else { break }
                start = next
            }
            let location = min(text.length, start + max(0, document.column - 1))
            let range = NSRange(location: location, length: min(document.selectionLength, text.length - location))
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
        }
        if coordinator.lastFindRequest != findRequest {
            coordinator.lastFindRequest = findRequest
            if isActive {
                let sender = NSMenuItem()
                sender.tag = NSTextFinder.Action.showFindInterface.rawValue
                textView.performTextFinderAction(sender)
            }
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.assistance?.shutdown()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSLayoutManagerDelegate {
        var lastDiagnostics: [JSONValue] = []
        var folds: [NSRange] = []
        var parent: CodeTextView
        weak var textView: NSTextView?
        weak var ruler: CodeLineRuler?
        var wasActive = false
        var lastFocusRequest = -1
        var lastFindRequest = 0
        var lastSelectionRequest = 0
        private var highlightTask: Task<Void, Never>?
        private var completionTask: Task<Void, Never>?
        private var parseTask: Task<Void, Never>?
        private var cachedSource: String?
        private var tokens: [CodeToken] = []
        var lastCompletionRequest = 0
        var lastNavigationRequest = 0
        var assistance: InlineCodeAssistant?

        init(_ parent: CodeTextView) {
            self.parent = parent
            lastFindRequest = parent.findRequest
        }

        func configureAssistance() {
            guard let view = textView as? CodeEditingTextView else { return }
            if assistance?.ide === parent.ide { return }
            assistance?.shutdown(); assistance = nil
            if let ide = parent.ide {
                assistance = InlineCodeAssistant(view: view, ide: ide, document: parent.document)
            }
            view.inlineAssistant = assistance
            view.onDismissAgentSuggestion = { [weak self] in self?.clearSuggestion() }
            ruler?.quickFix = { [weak self] line in
                guard let self, let starts = self.ruler?.lineStarts, starts.indices.contains(line - 1) else { return }
                let start = starts[line - 1]
                // Use the diagnostic start rather than column zero for the language request.
                let diagnostic = self.parent.diagnostics.first { $0["range"]?["start"]?["line"]?.int == line - 1 }
                let offset = diagnostic?["range"]?["start"].flatMap { try? SourcePosition.offset($0, in: self.parent.document.text) } ?? start
                self.assistance?.requestFixes(at: offset)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.document.text = textView.string
            if !parent.document.foldedRanges.isEmpty { parent.document.foldedRanges = [] }
            clearSuggestion()
            assistance?.textChanged()
            if parent.automaticCompletions { suggest(delay: true) }
            ruler?.updateLines()
            highlightTask?.cancel()
            highlightTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                self?.highlight()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            if (textView as? CodeEditingTextView)?.suggestionOffset != textView.selectedRange().location { clearSuggestion() }
            let location = textView.selectedRange().location
            let starts = ruler?.lineStarts ?? [0]
            let line = CodeLineRuler.lineIndex(at: location, starts: starts)
            parent.document.line = line + 1
            parent.document.column = location - starts[line] + 1
            parent.document.selectionLength = textView.selectedRange().length
            textView.needsDisplay = true
            ruler?.activeLine = line
            ruler?.needsDisplay = true
            highlightBrackets()
            assistance?.selectionChanged()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if let view = textView as? CodeEditingTextView, !view.suggestion.isEmpty {
                if selector == #selector(NSResponder.insertTab(_:)) {
                    let suggestion = view.suggestion
                    clearSuggestion()
                    view.insertText(suggestion, replacementRange: view.selectedRange())
                    return true
                }
                if selector == #selector(NSResponder.cancelOperation(_:)) { clearSuggestion(); return true }
            }
            if selector == #selector(NSResponder.insertTab(_:)), !parent.style.usesTabs {
                let source = textView.string as NSString, range = textView.selectedRange()
                let line = source.lineRange(for: NSRange(location: range.location, length: 0))
                let prefix = source.substring(with: NSRange(location: line.location, length: range.location - line.location))
                let width = parent.style.tabWidth
                let column = prefix.reduce(0) { $1 == "\t" ? $0 + width - $0 % width : $0 + 1 }
                textView.insertText(String(repeating: " ", count: width - column % width), replacementRange: range)
                return true
            }
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let source = textView.string as NSString
            let range = textView.selectedRange()
            let line = source.lineRange(for: NSRange(location: range.location, length: 0))
            let beforeCursor = source.substring(with: NSRange(location: line.location, length: range.location - line.location))
            let indent = String(beforeCursor.prefix { $0 == " " || $0 == "\t" })
            let extra = beforeCursor.trimmingCharacters(in: .whitespaces).hasSuffix("{") ? parent.style.indent : ""
            let newline = textView.string.contains("\r\n") ? "\r\n" : "\n"
            textView.insertText(newline + indent + extra, replacementRange: range)
            return true
        }

        func clearSuggestion() {
            completionTask?.cancel(); completionTask = nil
            (textView as? CodeEditingTextView)?.suggestion = ""
            parent.document.completionIsLoading = false
        }
        func suggest(delay: Bool) {
            clearSuggestion()
            if !delay { assistance?.dismiss() }
            guard parent.isActive, let view = textView as? CodeEditingTextView,
                  view.selectedRange().length == 0, let request = parent.requestCompletion else { return }
            let text = view.string, offset = view.selectedRange().location
            view.suggestionOffset = offset
            completionTask = Task { [weak self, weak view] in
                guard let self else { return }
                do {
                    if delay { try await Task.sleep(for: .milliseconds(900)) }
                    try Task.checkCancellation()
                    if delay, assistance?.isCompletionActive == true { return }
                    parent.document.completionIsLoading = true
                    parent.document.completionMessage = nil
                    let suggestion = try await request(text, offset)
                    try Task.checkCancellation()
                    guard let view, view.editorActive, view.string == text, view.selectedRange() == NSRange(location: offset, length: 0) else { return }
                    view.suggestion = suggestion
                    parent.document.completionMessage = suggestion.isEmpty ? "No suggestion" : "Tab to accept · Escape to dismiss"
                    parent.document.completionIsLoading = false
                } catch is CancellationError { }
                catch { parent.document.completionMessage = error.localizedDescription; parent.document.completionIsLoading = false }
            }
        }

        func highlight() {
            guard let textView else { return }
            let source = textView.string
            applyColors(cachedSource == source ? tokens : [])
            guard cachedSource != source else { return }
            parseTask?.cancel()
            let path = parent.document.path
            let worker = Task.detached(priority: .userInitiated) { CodeSyntax.tokens(in: source, path: path) }
            parseTask = Task { [weak self] in
                let tokens = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, let self, self.textView?.string == source else { return }
                self.cachedSource = source
                self.tokens = tokens
                self.applyColors(tokens)
            }
        }

        private func applyColors(_ tokens: [CodeToken]) {
            guard let textView, let storage = textView.textStorage else { return }
            let source = textView.string
            let full = NSRange(location: 0, length: (source as NSString).length)
            let base: [NSAttributedString.Key: Any] = [
                .font: parent.style.font, .foregroundColor: CodePalette.foreground,
                .paragraphStyle: parent.style.paragraph, .ligature: 0,
            ]
            storage.beginEditing()
            storage.setAttributes(base, range: full)
            for token in tokens where NSMaxRange(token.range) <= full.length {
                storage.addAttribute(.foregroundColor, value: CodePalette.token(token.kind), range: token.range)
                if token.kind == .comment {
                    storage.addAttribute(.font, value: NSFontManager.shared.convert(parent.style.font, toHaveTrait: .italicFontMask), range: token.range)
                }
            }
            for diagnostic in parent.diagnostics {
                if let start = diagnostic["range"]?["start"], let end = diagnostic["range"]?["end"],
                   let lower = try? SourcePosition.offset(start, in: source), let upper = try? SourcePosition.offset(end, in: source), upper >= lower, lower < full.length {
                    storage.addAttributes([.underlineStyle: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue,
                        .underlineColor: diagnostic["severity"]?.int == 1 ? NSColor.systemRed : NSColor.systemOrange], range: NSRange(location: lower, length: min(max(1, upper - lower), full.length - lower)))
                }
            }
            storage.endEditing()
            textView.typingAttributes = base
            textView.enclosingScrollView?.needsLayout = true
            textView.needsDisplay = true
            ruler?.needsDisplay = true
            highlightBrackets()
        }

        private func highlightBrackets() {
            guard let textView, let layout = textView.layoutManager else { return }
            let length = (textView.string as NSString).length
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
            let cursor = textView.selectedRange()
            guard cursor.length == 0, cachedSource == textView.string else { return }
            let brackets = tokens.filter { $0.kind == .punctuation && $0.range.length == 1 }
            let source = textView.string as NSString
            let pairs: [unichar: unichar] = [40: 41, 91: 93, 123: 125]
            guard let selected = brackets.firstIndex(where: { $0.range.location == cursor.location - 1 || $0.range.location == cursor.location }) else { return }
            let symbol = source.character(at: brackets[selected].range.location)
            let forward = pairs[symbol] != nil
            guard let target = pairs[symbol] ?? pairs.first(where: { $0.value == symbol })?.key else { return }
            var depth = 0
            let indices = forward ? Array(selected..<brackets.count) : Array((0...selected).reversed())
            for index in indices {
                let value = source.character(at: brackets[index].range.location)
                if value == symbol { depth += 1 }
                if value == target { depth -= 1 }
                if depth == 0 {
                    for match in [selected, index] { layout.addTemporaryAttribute(.backgroundColor, value: CodePalette.matchingBracket, forCharacterRange: brackets[match].range) }
                    break
                }
            }
        }

        func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>, properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes indexes: UnsafePointer<Int>, font: NSFont, forGlyphRange range: NSRange) -> Int {
            guard !folds.isEmpty else { return 0 }
            var properties = (0..<range.length).map { i in folds.contains(where: { NSLocationInRange(indexes[i], $0) }) ? NSLayoutManager.GlyphProperty.null : props[i] }
            layoutManager.setGlyphs(glyphs, properties: &properties, characterIndexes: indexes, font: font, forGlyphRange: range)
            return range.length
        }
        func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction, forControlCharacterAt index: Int) -> NSLayoutManager.ControlCharacterAction {
            folds.contains(where: { NSLocationInRange(index, $0) }) ? .zeroAdvancement : action
        }


    }
}

@MainActor
final class CodeEditingTextView: NSTextView {
    var editorStyle = EditorStyle()
    var onEditorAction: ((String) -> Void)?
    var onAppearanceChange: (() -> Void)?
    var foldedRanges: [NSRange] = []
    weak var inlineAssistant: InlineCodeAssistant?
    var onDismissAgentSuggestion: (() -> Void)?
    private var contextOffset: Int?
    private var hoverTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverTracking = area
    }
    override func mouseMoved(with event: NSEvent) { inlineAssistant?.mouseMoved(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { inlineAssistant?.mouseExited() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
        needsDisplay = true
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard editorActive, selectedRange().length == 0, let layout = layoutManager else { return }
        let offset = selectedRange().location
        let line = offset < (string as NSString).length
            ? layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: offset), effectiveRange: nil)
            : layout.extraLineFragmentRect
        let highlight = NSRect(x: 0, y: line.minY + textContainerInset.height, width: bounds.width, height: line.height)
        if highlight.intersects(rect) { CodePalette.activeLine.setFill(); highlight.fill() }
    }
    private func drawIndentGuides() {
        guard editorStyle.showsIndentGuides, let layout = layoutManager, let container = textContainer, !string.isEmpty else { return }
        let glyphs = layout.glyphRange(forBoundingRect: visibleRect.offsetBy(dx: -textContainerInset.width, dy: -textContainerInset.height), in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let text = string as NSString
        var start = text.lineRange(for: NSRange(location: min(chars.location, text.length - 1), length: 0)).location
        let space = (" " as NSString).size(withAttributes: [.font: editorStyle.font]).width
        let tabWidth = editorStyle.tabWidth
        let path = NSBezierPath(); path.lineWidth = 0.5
        while start < min(text.length, NSMaxRange(chars)) {
            let range = text.lineRange(for: NSRange(location: start, length: 0))
            defer { start = NSMaxRange(range) }
            if foldedRanges.contains(where: { NSLocationInRange(start, $0) }) { continue }
            var offset = start, columns = 0
            while offset < NSMaxRange(range) {
                let c = text.character(at: offset)
                if c == 32 { columns += 1 } else if c == 9 { columns += tabWidth - columns % tabWidth } else { break }
                offset += 1
            }
            if columns < tabWidth { continue }
            let line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: start), effectiveRange: nil)
            for column in stride(from: 0, to: min(columns, 80), by: tabWidth) {
                let x = textContainerInset.width + CGFloat(column) * space + 0.5
                path.move(to: NSPoint(x: x, y: line.minY + textContainerInset.height))
                path.line(to: NSPoint(x: x, y: line.maxY + textContainerInset.height))
            }
        }
        CodePalette.guide.setStroke(); path.stroke()
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        inlineAssistant?.dismiss()
        contextOffset = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let menu = NSMenu()
        for (title, command) in [("Show Documentation", "Inline Hover"), ("Quick Fix…", "Inline QuickFix"), ("Go to Definition", "Inline Definition"), ("Peek Definition", "Inline Peek"), ("Find References", "Inline References"), ("Rename Symbol…", "Rename"), ("Refactor…", "Refactor"), ("Format Document", "Format"), ("Organize Imports", "Organize imports")] {
            let item = NSMenuItem(title: title, action: #selector(runEditorAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = command
            item.isEnabled = onEditorAction != nil
            menu.addItem(item)
        }
        let snippets = NSMenuItem(title: "Insert Snippet", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for snippet in EditorSnippet.allCases {
            let item = NSMenuItem(title: snippet.title, action: #selector(runEditorAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = snippet.rawValue; submenu.addItem(item)
        }
        snippets.submenu = submenu; menu.addItem(snippets)
        menu.addItem(.separator())
        for (title, action) in [("Cut", #selector(cut(_:))), ("Copy", #selector(copy(_:))), ("Paste", #selector(paste(_:))), ("Select All", #selector(selectAll(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        return menu
    }
    @objc private func runEditorAction(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? String {
            if command == "Inline Hover" { inlineAssistant?.requestHover(at: contextOffset ?? selectedRange().location) }
            else if command == "Inline QuickFix" { inlineAssistant?.requestFixes(at: contextOffset) }
            else if command.hasPrefix("Inline ") {
                inlineAssistant?.requestNavigation(at: contextOffset, references: command == "Inline References", openDirectly: command == "Inline Definition")
            } else {
                if let offset = contextOffset { setSelectedRange(NSRange(location: offset, length: 0)) }
                onEditorAction?(command)
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        inlineAssistant?.dismiss()
        if event.modifierFlags.contains(.command) {
            let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            setSelectedRange(NSRange(location: index, length: 0))
            inlineAssistant?.requestNavigation(at: index, openDirectly: !event.modifierFlags.contains(.option))
        } else if event.modifierFlags.contains(.option) {
            let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            var ranges = selectedRanges.map(\.rangeValue)
            if !ranges.contains(where: { $0.location == index && $0.length == 0 }) { ranges.append(NSRange(location: index, length: 0)) }
            selectedRanges = ranges.sorted { $0.location < $1.location }.map(NSValue.init(range:))
        } else { super.mouseDown(with: event) }
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard selectedRanges.count > 1, let text = insertString as? String else { super.insertText(insertString, replacementRange: replacementRange); return }
        replaceSelections(text)
    }
    override func deleteBackward(_ sender: Any?) {
        guard selectedRanges.count > 1 else { super.deleteBackward(sender); return }
        selectedRanges = selectedRanges.map { value in
            let range = value.rangeValue
            return NSValue(range: range.length == 0 && range.location > 0 ? (string as NSString).rangeOfComposedCharacterSequence(at: range.location - 1) : range)
        }
        replaceSelections("")
    }
    private func replaceSelections(_ replacement: String) {
        guard let (text, ranges) = try? EditorOperations.replace(string, ranges: selectedRanges.map(\.rangeValue), with: replacement) else { return }
        restoreText(text, ranges: ranges)
    }
    private func restoreText(_ text: String, ranges: [NSRange]) {
        let previous = string, selection = selectedRanges.map(\.rangeValue)
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restoreText(previous, ranges: selection) }
        }
        string = text; selectedRanges = ranges.map(NSValue.init(range:)); didChangeText()
    }
    func applyAssistanceText(_ text: String, selection: NSRange, action: String) {
        breakUndoCoalescing()
        // A response can arrive inside the same AppKit undo event as the typed
        // prefix. Finish that event so accepting a suggestion is its own step.
        if let manager = undoManager, !manager.isUndoing, !manager.isRedoing {
            while manager.groupingLevel > 0 { manager.endUndoGrouping() }
        }
        undoManager?.beginUndoGrouping()
        restoreText(text, ranges: [selection])
        undoManager?.setActionName(action)
        undoManager?.endUndoGrouping()
        scrollRangeToVisible(selection)
    }
    var onRequestCompletion: (() -> Void)?
    var suggestion = "" { didSet { needsDisplay = true } }
    var suggestionOffset = 0
    override func keyDown(with event: NSEvent) {
        if inlineAssistant?.keyDown(event) == true { return }
        if event.charactersIgnoringModifiers == "d", event.modifierFlags.contains(.command) {
            var ranges = selectedRanges.map(\.rangeValue)
            if ranges.first?.length == 0 {
                setSelectedRange(selectionRange(forProposedRange: selectedRange(), granularity: .selectByWord)); return
            }
            guard let first = ranges.first, first.length > 0 else { return }
            let source = string as NSString, token = source.substring(with: first), end = ranges.map(NSMaxRange).max() ?? 0
            var next = source.range(of: token, range: NSRange(location: end, length: source.length - end))
            if next.location == NSNotFound { next = source.range(of: token) }
            if next.location != NSNotFound && !ranges.contains(next) { ranges.append(next); selectedRanges = ranges.map(NSValue.init(range:)) }
            return
        }
        if event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control {
            onRequestCompletion?(); return
        }
        super.keyDown(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawIndentGuides()
        guard editorActive, !suggestion.isEmpty, selectedRange() == NSRange(location: suggestionOffset, length: 0), let window else { return }
        let caret = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        let rect = convert(window.convertFromScreen(caret), from: nil)
        (suggestion as NSString).draw(at: NSPoint(x: rect.minX, y: rect.minY), withAttributes: [.font: editorStyle.font, .foregroundColor: NSColor.tertiaryLabelColor])
    }
    var editorActive = true { didSet { inlineAssistant?.setActive(editorActive) } }
    override var acceptsFirstResponder: Bool { editorActive && super.acceptsFirstResponder }
    override var canBecomeKeyView: Bool { editorActive && super.canBecomeKeyView }
    var documentID: UUID?
    private var wantsEditorFocus = false
    private let documentUndoManager = UndoManager()
    override var undoManager: UndoManager? { documentUndoManager }

    func requestEditorFocus() {
        wantsEditorFocus = true
        DispatchQueue.main.async { [weak self] in self?.applyEditorFocus() }
    }

    func cancelEditorFocus() { wantsEditorFocus = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        applyEditorFocus()
    }

    private func applyEditorFocus() {
        guard wantsEditorFocus, let window else { return }
        wantsEditorFocus = !window.makeFirstResponder(self)
    }
}

/// Keep TextKit's container finite and size the document to its laid-out height.
@MainActor
private final class CodeScrollView: NSScrollView {
    var wrapsLines = false
    override func layout() {
        super.layout()
        guard let textView = documentView as? NSTextView,
            let layout = textView.layoutManager, let container = textView.textContainer
        else { return }
        // TextKit may reveal a small negative origin when bringing the caret beside
        // the ruler into view. Wrapped lines must still end inside the visible edge.
        let width = max(1, contentView.bounds.width + (wrapsLines ? min(0, contentView.bounds.minX) : 0))
        if wrapsLines, textView.frame.width != width { textView.setFrameSize(NSSize(width: width, height: textView.frame.height)) }
        container.containerSize = NSSize(width: wrapsLines ? max(1, width - textView.textContainerInset.width * 2) : 10_000_000, height: 10_000_000)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        // The extra empty line at EOF can make usedRect as wide as the container.
        // Measure actual line contents so scrolling ends at the longest source line.
        var contentWidth: CGFloat = 0
        if !wrapsLines {
            layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, line, _, _, _ in
                contentWidth = max(contentWidth, line.maxX)
            }
        }
        let size = NSSize(
            width: wrapsLines ? width : max(width, ceil(contentWidth) + textView.textContainerInset.width * 2 + 10),
            height: max(contentView.bounds.height, ceil(used.maxY) + textView.textContainerInset.height * 2 + 20))
        if textView.frame.size != size { textView.setFrameSize(size) }
    }
}

@MainActor
final class CodeLineRuler: NSRulerView {
    var activeLine = 0
    var breakpoints: Set<Int> = []
    var coverage: [Int: Bool] = [:]
    var folds: [NSRange] = []
    var toggleBreakpoint: ((Int) -> Void)?
    var diagnosticLines: Set<Int> = []
    var quickFix: ((Int) -> Void)?
    private weak var textView: NSTextView?
    private(set) var lineStarts = [0]
    override var isFlipped: Bool { true }

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 60
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateLines() {
        guard let textView else { return }
        let source = textView.string as NSString
        lineStarts = [0]
        var position = 0
        while position < source.length {
            let range = source.lineRange(for: NSRange(location: position, length: 0))
            position = NSMaxRange(range)
            if position < source.length { lineStarts.append(position) }
        }
        if textView.string.hasSuffix("\n") || textView.string.hasSuffix("\r") { lineStarts.append(source.length) }
        ruleThickness = max(60, CGFloat(String(lineStarts.count).count) * 8 + 34)
        needsDisplay = true
    }

    static func lineIndex(at location: Int, starts: [Int]) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= location { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        CodePalette.gutter.setFill()
        bounds.fill()
        CodePalette.guide.setFill()
        NSRect(x: bounds.maxX - 0.5, y: bounds.minY, width: 0.5, height: bounds.height).fill()
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let visible = textView.visibleRect.offsetBy(dx: -textView.textContainerInset.width, dy: -textView.textContainerInset.height)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = Self.lineIndex(at: characters.location, starts: lineStarts)
        let last = min(lineStarts.count - 1, Self.lineIndex(at: NSMaxRange(characters), starts: lineStarts) + 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: CodePalette.lineNumber,
        ]
        for index in first...last {
            let character = lineStarts[index]
            if folds.contains(where: { NSLocationInRange(character, $0) }) { continue }
            let lineRect: NSRect
            if character < (textView.string as NSString).length {
                lineRect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: character), effectiveRange: nil)
            } else {
                lineRect = layout.extraLineFragmentRect
            }
            let point = convert(NSPoint(x: 0, y: lineRect.minY + textView.textContainerInset.height), from: textView)
            if let covered = coverage[index + 1] {
                (covered ? NSColor.systemGreen : NSColor.systemRed).withAlphaComponent(0.7).setFill()
                NSRect(x: 0, y: point.y, width: 3, height: max(12, lineRect.height)).fill()
            }
            if breakpoints.contains(index + 1) { NSColor.systemRed.setFill(); NSBezierPath(ovalIn: NSRect(x: 5, y: point.y + 3, width: 8, height: 8)).fill() }
            if diagnosticLines.contains(index + 1) {
                let icon = NSImage(systemSymbolName: "lightbulb", accessibilityDescription: "Show quick fixes")?
                    .withSymbolConfiguration(.init(paletteColors: [.systemYellow]))
                icon?.draw(in: NSRect(x: 17, y: point.y + 2, width: 11, height: 14), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let label = String(index + 1) as NSString
            var style = attributes
            if index == activeLine { style[.foregroundColor] = CodePalette.foreground }
            label.draw(at: NSPoint(x: ruleThickness - label.size(withAttributes: attributes).width - 12, y: point.y + 2), withAttributes: style)
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let textView else { return }
        let rulerPoint = convert(event.locationInWindow, from: nil)
        let point = textView.convert(rulerPoint, from: self)
        let index = textView.characterIndexForInsertion(at: point)
        let line = Self.lineIndex(at: index, starts: lineStarts) + 1
        if (15...30).contains(rulerPoint.x), diagnosticLines.contains(line) { quickFix?(line) }
        else { toggleBreakpoint?(line) }
    }
}
