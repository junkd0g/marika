import AppKit
import MarikaCore
import SwiftUI

struct MarkdownModeBar: View {
    @Bindable var document: CodeDocument
    let editor: CodeWorkspace

    var body: some View {
        HStack(spacing: 8) {
            Label("Markdown", systemImage: "doc.richtext").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                ForEach(MarkdownPresentation.allCases, id: \.self) { mode in
                    Button {
                        document.markdownPresentation = mode
                        if mode != .preview { editor.focusEditor() }
                    } label: {
                        Text(mode.rawValue).font(.system(size: 11, weight: document.markdownPresentation == mode ? .semibold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(document.markdownPresentation == mode ? Theme.canvas : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain).accessibilityAddTraits(document.markdownPresentation == mode ? .isSelected : [])
                    #if DEBUG
                        .background(DebugViewMarker(name: "markdown-mode-" + mode.rawValue.lowercased()))
                    #endif
                }
            }
            .padding(3).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 12).padding(.vertical, 6).background(Theme.chrome.opacity(0.4))
    }
}

/// Keeps the native source editor mounted so preview changes never discard undo or selection.
struct MarkdownEditorPane<Source: View>: View {
    @Bindable var document: CodeDocument
    let editor: CodeWorkspace
    @ViewBuilder var source: () -> Source
    @State private var fraction = 0.5
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geometry in
            let split = document.markdownPresentation == .split
            let stacked = split && geometry.size.width < 640
            let length = (stacked ? geometry.size.height : geometry.size.width) - 6
            let first = floor(max(0, length) * fraction)
            ZStack(alignment: .topLeading) {
                source()
                    .frame(width: split && !stacked ? first : geometry.size.width,
                           height: split && stacked ? first : geometry.size.height)
                    .clipped()
                    .opacity(document.markdownPresentation == .preview ? 0 : 1)
                    .allowsHitTesting(document.markdownPresentation != .preview)
                    .accessibilityHidden(document.markdownPresentation == .preview)
                if document.markdownPresentation != .source {
                    MarkdownFilePreview(document: document, editor: editor)
                        .frame(width: split && !stacked ? max(0, length - first) : geometry.size.width,
                               height: split && stacked ? max(0, length - first) : geometry.size.height)
                        .clipped()
                        .offset(x: split && !stacked ? first + 6 : 0, y: split && stacked ? first + 6 : 0)
                }
                if split {
                    Rectangle().fill(Theme.hairline)
                        .frame(width: stacked ? geometry.size.width : 6, height: stacked ? 6 : geometry.size.height)
                        .offset(x: stacked ? 0 : first, y: stacked ? first : 0)
                        .gesture(DragGesture().onChanged { value in
                            if dragStart == nil { dragStart = fraction }
                            let delta = stacked ? value.translation.height : value.translation.width
                            fraction = min(0.75, max(0.25, (dragStart ?? 0.5) + delta / max(1, length)))
                        }.onEnded { _ in dragStart = nil })
                        .help("Resize Markdown editor and preview")
                }
            }
        }
    }
}

private struct MarkdownFilePreview: View {
    @Bindable var document: CodeDocument
    let editor: CodeWorkspace
    @State private var blocks: [MarkdownBlock] = []
    private var url: URL { editor.root.appendingPathComponent(document.path) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ContentUnavailableView("Your document starts here", systemImage: "doc.richtext",
                            description: Text("Choose Edit or Split to start writing Markdown."))
                    } else {
                        MarkdownView(text: document.text, documentURL: url, parsedBlocks: blocks,
                            onOpenLink: { link in open(link, proxy: proxy) })
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(28).frame(maxWidth: .infinity, alignment: .top)
            }
            .background(Theme.canvas)
            .environment(\.projectRoot, editor.root)
            .task(id: document.revision) {
                if !blocks.isEmpty { try? await Task.sleep(for: .milliseconds(140)) }
                guard !Task.isCancelled else { return }
                let text = document.text
                let parsed = await Task.detached(priority: .userInitiated) { MarkdownParser.parse(text) }.value
                guard !Task.isCancelled else { return }
                blocks = parsed
                await Task.yield()
                if let anchor = document.markdownAnchor, !blocks.isEmpty {
                    proxy.scrollTo(anchor, anchor: .top)
                    document.markdownAnchor = nil
                }
            }
            .onChange(of: document.markdownAnchor) { _, anchor in
                if let anchor, !blocks.isEmpty {
                    proxy.scrollTo(anchor, anchor: .top)
                    document.markdownAnchor = nil
                }
            }
            #if DEBUG
                .background(DebugViewMarker(name: "markdown-preview"))
            #endif
        }
    }

    private func open(_ link: URL, proxy: ScrollViewProxy) -> OpenURLAction.Result {
        if ["https", "http", "mailto"].contains(link.scheme?.lowercased() ?? "") { return .systemAction }
        guard let target = MarkdownResource.localURL(link.relativeString, document: url, root: editor.root) else { return .discarded }
        if target.standardizedFileURL == url.standardizedFileURL.resolvingSymlinksInPath() {
            if let anchor = link.fragment?.removingPercentEncoding { proxy.scrollTo(anchor, anchor: .top) }
        } else {
            let path = String(target.path.dropFirst(editor.root.standardizedFileURL.resolvingSymlinksInPath().path.count + 1))
            Task {
                await editor.open(path, focus: false)
                if let selected = editor.selectedDocument, selected.path == path, selected.isMarkdown {
                    selected.markdownPresentation = .preview
                    selected.markdownAnchor = link.fragment?.removingPercentEncoding
                }
            }
        }
        return .handled
    }
}

struct MarkdownImage: View {
    let alt: String
    let source: String
    let documentURL: URL
    let root: URL
    @State private var localImage: NSImage?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let localImage {
                Image(nsImage: localImage).resizable().scaledToFit().frame(maxHeight: 500)
                    .accessibilityLabel(alt)
            } else if let remote = URL(string: source), ["https", "http"].contains(remote.scheme?.lowercased() ?? "") {
                AsyncImage(url: remote) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit().frame(maxHeight: 500)
                    case .empty: ProgressView().controlSize(.small).padding(16)
                    case .failure: imagePlaceholder
                    @unknown default: imagePlaceholder
                    }
                }.accessibilityLabel(alt)
            } else { imagePlaceholder }
            if !alt.isEmpty { Text(alt).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .task(id: source) {
            localImage = nil; loaded = false
            if let url = MarkdownResource.localURL(source, document: documentURL, root: root) {
                let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                          values.isRegularFile == true, (values.fileSize ?? Int.max) <= 20_000_000 else { return nil }
                    return try? Data(contentsOf: url)
                }.value
                if let data { localImage = NSImage(data: data) }
            }
            loaded = true
        }
    }

    private var imagePlaceholder: some View {
        Label(loaded ? "Image unavailable" : "Loading image…", systemImage: "photo")
            .font(.system(size: 12)).foregroundStyle(.secondary).padding(16).surface()
    }
}
