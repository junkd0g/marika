import AppKit
import MarikaCore
import SwiftUI
import WebKit

struct ProjectBrowserView: View {
    @Environment(AppModel.self) private var model
    @Bindable var browser: BrowserWorkspace
    let project: Project
    var isVisible: Bool
    @State private var detectedPreview: PreviewConfiguration?
    @State private var address = ""
    @State private var hoveredTab: UUID?
    @State private var suggestionIndex: Int?
    @State private var showsSiteInfo = false
    @State private var showsFind = false
    @State private var showsPreviewLogs = false
    @FocusState private var addressFocused: Bool
    @FocusState private var findFocused: Bool

    private var suggestions: [BrowserLocation] { browser.library.suggestions(for: address, limit: 5) }
    private var canRecoverPreview: Bool {
        PreviewRecovery.matches(browser.selectedPage?.url, configuration: project.previewConfiguration ?? detectedPreview,
            runningAddress: model.previews[project.id]?.address)
    }

    var body: some View {
        VStack(spacing: 0) {
            if project.previewConfiguration != nil || detectedPreview != nil || model.previews[project.id] != nil {
                previewBar
            }
            tabs
            navigation.zIndex(10)
            GeometryReader { geometry in
                Rectangle().fill(Color.accentColor)
                    .frame(width: geometry.size.width * (browser.selectedPage?.isLoading == true ? max(0.03, browser.selectedPage?.progress ?? 0) : 0))
                    .animation(.easeOut(duration: 0.2), value: browser.selectedPage?.progress)
            }
            .frame(height: 2).background(Theme.hairline)
            if let error = browser.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.attention)
                    Text(error).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { browser.errorMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss browser error")
                }
                .padding(12).background(Theme.attention.opacity(0.08))
            }
            if showsFind { findBar }
            if browser.annotation != nil { annotationForm }
            if browser.selectedPage?.isAnnotating == true {
                HStack {
                    Label("Click an element in the page to leave feedback.", systemImage: "cursorarrow")
                    Spacer()
                    Button("Cancel") { Task { await browser.annotate() } }
                }
                .font(.system(size: 12)).padding(10).background(Color.accentColor.opacity(0.08))
            }
            HStack(spacing: 0) {
                pageContent
                if showsPreviewLogs, let preview = model.previews[project.id] {
                    Divider()
                    PreviewLogView(preview: preview).frame(width: 270)
                }
            }
            Divider()
            footer
        }
        .background(Theme.canvas)
        .sheet(isPresented: $browser.showsHistory) { BrowserLibraryView(browser: browser) }
        .onAppear { syncAddress() }
        .task(id: browser.selectedPage?.navigationError) {
            let root = project.url
            let detected = await Task.detached { ProjectPreview.detect(at: root) }.value
            if !Task.isCancelled { detectedPreview = detected }
        }
        .onChange(of: browser.selectedPageID) { _, _ in
            addressFocused = false
            syncAddress()
            suggestionIndex = nil
        }
        .onChange(of: browser.selectedPage?.url) { _, _ in if !addressFocused { syncAddress() } }
        .onChange(of: address) { _, _ in suggestionIndex = nil }
        .onChange(of: browser.addressFocusRequest) { _, _ in focusAddress() }
        .onChange(of: browser.findRequest) { _, _ in focusFind() }
        .onChange(of: addressFocused) { _, focused in
            if focused {
                DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
            }
        }
        .onChange(of: isVisible) { _, visible in
            if !visible { addressFocused = false; findFocused = false }
        }
    }

    private var previewBar: some View {
        let preview = model.previews[project.id]
        return HStack(spacing: 10) {
            PreviewStatusLabel(preview: preview)
            if let port = preview?.address?.port {
                Text(verbatim: ":\(port)").monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(preview?.isActive == true ? "Stop" : "Start") {
                if let preview, preview.isActive { preview.stop() }
                else { model.runPreview(for: project) }
            }
            Button(showsPreviewLogs ? "Hide Logs" : "Logs") {
                _ = model.preview(for: project)
                showsPreviewLogs.toggle()
            }
            .accessibilityLabel("Toggle preview logs")
            #if DEBUG
                .background(DebugViewMarker(name: "preview-toggle-logs"))
            #endif
            Button("Settings…") { model.openPreviewSettings(for: project) }
        }
        .font(.system(size: 11)).controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 7).background(Theme.panel)
        #if DEBUG
            .background(DebugViewMarker(name: "preview-status-bar"))
        #endif
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 3) {
                        ForEach(browser.pages) { page in tab(page).id(page.id) }
                    }
                    .padding(.leading, 8).padding(.top, 7)
                }
                .scrollIndicators(.hidden)
                .onChange(of: browser.selectedPageID) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                }
            }
            iconButton("plus", label: "New browser tab (⌘T)") { browser.newTab() }
                .padding(.trailing, 8)
        }
        .frame(height: 41).background(Theme.chrome)
    }

    private func tab(_ page: BrowserPage) -> some View {
        let selected = page.id == browser.selectedPageID
        return HStack(spacing: 7) {
            Button { browser.selectedPageID = page.id } label: {
                HStack(spacing: 7) {
                    if page.isLoading {
                        ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                    } else if let favicon = page.favicon {
                        Image(nsImage: favicon).resizable().scaledToFit().frame(width: 14, height: 14)
                    } else { siteIcon(page.url).frame(width: 14, height: 14) }
                    Text(page.title).font(.system(size: 11.5, weight: selected ? .medium : .regular))
                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(BrowserTabInteraction(pageID: page.id, title: page.title,
                select: { browser.selectedPageID = page.id }, close: { browser.close(page) }, move: { id, after in
                    guard browser.pages.contains(where: { $0.id == id }) else { return false }
                    browser.moveTab(id, before: page.id, after: after)
                    return true
                }).frame(maxWidth: .infinity, maxHeight: .infinity))
            Button { browser.close(page) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary).frame(width: 20, height: 22)
                    .background(hoveredTab == page.id ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain).accessibilityLabel("Close browser tab \(page.title)")
        }
        .padding(.horizontal, 10).frame(width: 190, height: 33)
        .background(selected ? Theme.canvas : hoveredTab == page.id ? Theme.surface : .clear,
                    in: UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
        .overlay(alignment: .bottom) { if selected { Color.accentColor.opacity(0.8).frame(height: 2) } }
        .onHover { hoveredTab = $0 ? page.id : nil }
        .help(page.url?.absoluteString ?? "New tab")
        .contextMenu {
            Button("New Tab") { browser.newTab() }
            Button("Duplicate Tab") { browser.newPage(url: page.url) }
            Button("Reload Tab") { page.reload() }.disabled(page.url == nil)
            Divider()
            Button("Close Tab") { browser.close(page) }
            Button("Close Other Tabs") {
                for other in browser.pages where other.id != page.id { browser.close(other) }
            }.disabled(browser.pages.count < 2)
            Button("Reopen Closed Tab") { browser.reopenClosedTab() }.disabled(browser.closedTabs.isEmpty)
        }
    }

    private var navigation: some View {
        HStack(spacing: 4) {
            iconButton("chevron.left", label: "Back (⌘[)") { browser.selectedPage?.webView.goBack() }
                .disabled(browser.selectedPage?.canGoBack != true)
                .contextMenu { historyMenu(backwards: true) }
            iconButton("chevron.right", label: "Forward (⌘])") { browser.selectedPage?.webView.goForward() }
                .disabled(browser.selectedPage?.canGoForward != true)
                .contextMenu { historyMenu(backwards: false) }
            iconButton(browser.selectedPage?.isLoading == true ? "xmark" : "arrow.clockwise",
                       label: browser.selectedPage?.isLoading == true ? "Stop loading (Esc)" : "Reload page (⌘R)") {
                if browser.selectedPage?.isLoading == true { browser.selectedPage?.webView.stopLoading() }
                else { browser.selectedPage?.reload() }
            }.disabled(browser.selectedPage?.url == nil)
            addressBar.padding(.horizontal, 5).layoutPriority(1)
            iconButton("clock", label: "History and bookmarks") { browser.showLibrary("History") }
            iconButton("arrow.down.circle", label: "Downloads") { browser.showsDownloads.toggle() }
                .overlay(alignment: .topTrailing) {
                    if browser.downloads.contains(where: \.isRunning) {
                        Circle().fill(Color.accentColor).frame(width: 5, height: 5).allowsHitTesting(false)
                    }
                }
                .popover(isPresented: $browser.showsDownloads, arrowEdge: .bottom) { downloadsPanel }
            browserMenu
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.canvas)
    }

    private var addressBar: some View {
        HStack(spacing: 6) {
            Button { showsSiteInfo.toggle() } label: {
                Image(systemName: addressFocused ? "magnifyingglass" : securitySymbol)
                    .foregroundStyle(.secondary).frame(width: 23, height: 25)
            }
            .buttonStyle(.plain).help("Page information").accessibilityLabel("Page information")
            .popover(isPresented: $showsSiteInfo) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(browser.selectedPage?.url?.host ?? "Project browser").font(.headline)
                    Text(siteDescription).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("Cookies and sign-ins are saved separately for this project.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(18).frame(width: 280, alignment: .leading)
            }
            TextField("Search or enter address", text: $address)
                .textFieldStyle(.plain).font(.system(size: 12)).focused($addressFocused)
                .onSubmit {
                    if let suggestionIndex, suggestions.indices.contains(suggestionIndex) {
                        open(suggestions[suggestionIndex].url.absoluteString)
                    } else { open(address) }
                }
                .onKeyPress(.downArrow) {
                    guard !suggestions.isEmpty else { return .ignored }
                    suggestionIndex = min((suggestionIndex ?? -1) + 1, suggestions.count - 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    suggestionIndex = suggestionIndex.flatMap { $0 > 0 ? $0 - 1 : nil }
                    return .handled
                }
                .onKeyPress(.escape) { addressFocused = false; syncAddress(); return .handled }
                .accessibilityLabel("Browser address")
            if let url = browser.selectedPage?.url {
                iconButton(browser.library.isBookmarked(url) ? "star.fill" : "star", label: "Bookmark this page (⌘D)") {
                    browser.toggleBookmark()
                }
                .foregroundStyle(browser.library.isBookmarked(url) ? Color.accentColor : .secondary)
            }
        }
        .padding(.horizontal, 7).frame(height: 34)
        .background(addressFocused ? Theme.canvas : Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(addressFocused ? Color.accentColor.opacity(0.75) : Theme.hairline, lineWidth: addressFocused ? 1.5 : 1) }
        .overlay(alignment: .top) {
            if addressFocused, !suggestions.isEmpty {
                VStack(spacing: 2) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, location in
                        Button { open(location.url.absoluteString) } label: {
                            locationRow(location)
                                .padding(8).background(suggestionIndex == index ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(5).floatingPanel(cornerRadius: 9).padding(.top, 40)
            }
        }
    }

    private var browserMenu: some View {
        Menu {
            Button("New Tab", action: browser.newTab)
            Button("Reopen Closed Tab", action: browser.reopenClosedTab).disabled(browser.closedTabs.isEmpty)
            Button("Open HTML File…", action: chooseFile)
            Divider()
            Button("Find in Page…", action: focusFind).disabled(browser.selectedPage?.url == nil)
            Menu("Page Zoom · \(Int((browser.selectedPage?.zoom ?? 1) * 100))%") {
                Button("Zoom In") { browser.selectedPage?.changeZoom(0.1) }
                Button("Zoom Out") { browser.selectedPage?.changeZoom(-0.1) }
                Button("Actual Size") { browser.selectedPage?.zoom = 1 }
            }
            Menu("Bookmarks") {
                Button("Bookmark This Page", action: browser.toggleBookmark).disabled(browser.selectedPage?.url == nil)
                Button("Manage Bookmarks…") { browser.showLibrary("Bookmarks") }
                Divider()
                ForEach(browser.library.bookmarks) { location in
                    Button(location.title) { open(location.url.absoluteString) }
                }
                if browser.library.bookmarks.isEmpty { Text("No bookmarks yet") }
            }
            Divider()
            Button("Website Data…") { browser.showLibrary("Website Data") }
            Button("Comment on an Element") { Task { await browser.annotate() } }.disabled(browser.selectedPage?.url == nil)
            Button("Attach Screenshot to Chat") { Task { await browser.attachFeedback() } }
                .disabled(browser.selectedPage?.url == nil || browser.isCapturing)
            Menu("Agent Access") {
                Toggle("Allow agents on local previews", isOn: $browser.allowsLocalAgentAccess)
                if let url = browser.selectedPage?.url, !url.isFileURL, !BrowserAddress.isLocal(url) {
                    Toggle("Allow agents on \(url.host ?? "this site")", isOn: Binding(
                        get: { browser.allowedOrigins.contains(BrowserAddress.origin(url)) }, set: browser.allowCurrentSite))
                }
                Text("Page content is shared when you use browser tools or attach feedback.")
            }
        } label: { Image(systemName: "ellipsis").frame(width: 27, height: 28) }
        .menuStyle(.borderlessButton).fixedSize().help("Browser menu").accessibilityLabel("Browser menu")
    }

    private var pageContent: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width, browser.viewport == "Mobile" ? 390 : browser.viewport == "Tablet" ? 768 : geometry.size.width)
            ZStack {
                Theme.surface
                ForEach(browser.pages) { page in
                    BrowserWebView(page: page, isActive: isVisible && page.id == browser.selectedPageID)
                        .frame(width: width, height: geometry.size.height).clipped()
                        .opacity(page.id == browser.selectedPageID ? 1 : 0)
                        .allowsHitTesting(page.id == browser.selectedPageID)
                        .accessibilityHidden(page.id != browser.selectedPageID)
                }
                if browser.selectedPage?.url == nil { startPage }
                else if let error = browser.selectedPage?.navigationError {
                    VStack(spacing: 14) {
                        Image(systemName: "wifi.exclamationmark").font(.system(size: 30)).foregroundStyle(.secondary)
                        Text("Couldn't load this page").font(.system(size: 20, weight: .semibold))
                        Text(browser.selectedPage?.url?.absoluteString ?? "").font(.system(size: 12)).textSelection(.enabled)
                        Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                        if canRecoverPreview {
                            previewRecovery
                        } else if browser.selectedPage?.url.map(BrowserAddress.isLocal) == true {
                            Text("Make sure your development server is running.").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        if !canRecoverPreview {
                            Button("Try Again") { browser.selectedPage?.reload() }.buttonStyle(.borderedProminent)
                        }
                    }
                    .multilineTextAlignment(.center).padding(30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.canvas)
                }
            }
        }.clipped()
    }

    private var previewRecovery: some View {
        let preview = model.previews[project.id]
        return VStack(spacing: 10) {
            if preview?.state == .starting {
                HStack { ProgressView().controlSize(.small); Text("Starting project preview…") }
            } else if let error = preview?.error {
                Text(error).foregroundStyle(Theme.attention).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(preview?.state == .running ? "The project preview is running. Reload this page or check its logs." : "Your project's preview server is stopped. Start it to reopen this page.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button(preview?.state == .failed ? "Retry Preview" : "Start Preview") {
                    guard let page = browser.selectedPage else { return }
                    model.runPreview(for: project, recovering: page)
                }
                .buttonStyle(.borderedProminent).disabled(preview?.isActive == true)
                #if DEBUG
                    .background(DebugViewMarker(name: "browser-start-project-preview"))
                #endif
                Button("Reload Page") { browser.selectedPage?.reload() }
                    .disabled(preview?.state == .starting)
            }
            Button("Preview Settings & Logs…") { model.openPreviewSettings(for: project) }.buttonStyle(.link)
        }
        .font(.system(size: 12)).controlSize(.small)
    }

    private var startPage: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "globe").font(.system(size: 30, weight: .light)).foregroundStyle(Color.accentColor).padding(.bottom, 5)
                        Text("Your project, on the web.").font(.system(size: 26, weight: .semibold))
                        Text("Search the web, open a site, or preview what you're building.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Button(action: focusAddress) {
                        HStack {
                            Image(systemName: "magnifyingglass")
                            Text("Search or enter address")
                            Spacer()
                            Text("⌘L").font(.system(size: 11))
                        }.font(.system(size: 13)).foregroundStyle(.secondary)
                            .padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline) }
                    }.buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("LOCAL PREVIEWS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Button("localhost:3000") { open("http://localhost:3000") }
                            Button("localhost:5173") { open("http://localhost:5173") }
                            Button("Open HTML…", action: chooseFile)
                        }.controlSize(.small)
                    }
                    if !browser.library.bookmarks.isEmpty {
                        startSection("BOOKMARKS", locations: Array(browser.library.bookmarks.prefix(4)))
                    }
                    if !browser.library.history.isEmpty {
                        startSection("RECENTLY VISITED", locations: Array(browser.library.history.prefix(4)))
                    }
                    Text("Browsing data stays with this project. Agent access is controlled separately.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: 480).padding(32).frame(maxWidth: .infinity)
                .padding(.top, max(16, geometry.size.height * 0.10))
            }.background(Theme.canvas)
        }
    }

    private func startSection(_ title: String, locations: [BrowserLocation]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(locations) { location in
                Button { open(location.url.absoluteString) } label: { locationRow(location).padding(.vertical, 4) }
                    .buttonStyle(.plain)
            }
        }
    }

    private var downloadsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Downloads").font(.headline)
            if browser.downloads.isEmpty {
                Text("Downloaded files appear here.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(browser.downloads) { download in
                        HStack {
                            Image(systemName: download.state == .failed ? "exclamationmark.triangle" : "doc")
                                .foregroundStyle(download.state == .failed ? Theme.attention : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(download.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(download.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                                if download.state == .downloading {
                                    if let progress = download.fractionCompleted { ProgressView(value: progress) }
                                    else { ProgressView().controlSize(.mini) }
                                }
                            }
                            Spacer()
                            if download.canCancel {
                                Button("Cancel") { download.cancel() }.controlSize(.small)
                            } else if download.state == .completed, let url = download.fileURL {
                                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                                    .help("Show in Finder")
                            } else if download.canRetry {
                                Button("Retry") { download.retry() }.controlSize(.small)
                            }
                        }
                    }
                }
            }.frame(maxHeight: 300)
        }.padding(16).frame(width: 330)
    }

    private var findBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in page", text: Binding(get: { browser.selectedPage?.findText ?? "" }, set: {
                browser.selectedPage?.findText = $0; browser.selectedPage?.find()
            }))
            .textFieldStyle(.plain).focused($findFocused).onSubmit { browser.selectedPage?.find() }
            .task { findFocused = true }
            .accessibilityLabel("Find in page")
            if browser.selectedPage?.findFound == false { Text("No matches").foregroundStyle(.secondary) }
            iconButton("chevron.up", label: "Previous match") { browser.selectedPage?.find(backwards: true) }
            iconButton("chevron.down", label: "Next match") { browser.selectedPage?.find() }
            iconButton("xmark", label: "Close find") { closeFind() }
        }
        .font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 5).background(Theme.panel)
        .onKeyPress(.escape) { closeFind(); return .handled }
    }

    private var annotationForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(browser.annotation?["selector"]?.string ?? "Selected element", systemImage: "cursorarrow.click")
                    .font(Theme.codeSmall).lineLimit(1)
                Spacer()
                Button { browser.clearFeedback() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Cancel browser comment")
            }
            HStack {
                TextField("What should change here?", text: $browser.comment).textFieldStyle(.roundedBorder)
                Button(browser.isCapturing ? "Capturing…" : "Add to Message") { Task { await browser.attachFeedback() } }
                    .disabled(browser.isCapturing || browser.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Includes the page URL, element, viewport, and a screenshot. Review your draft before sending.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }.padding(12).background(Color.accentColor.opacity(0.07))
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            footerContents(compact: false)
            footerContents(compact: true)
        }
        .font(.system(size: 10.5)).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 6).background(Theme.chrome)
    }

    private func footerContents(compact: Bool) -> some View {
        HStack(spacing: 12) {
            Picker("Viewport", selection: $browser.viewport) {
                Text("Desktop").tag("Desktop")
                Text("Tablet · 768").tag("Tablet")
                Text("Mobile · 390").tag("Mobile")
            }.labelsHidden().frame(width: 125).controlSize(.small)
            if !compact {
                Label(browser.canUseAgent ? "Agent access on" : "Agent access off", systemImage: "person.crop.circle")
                    .fixedSize()
            }
            Spacer(minLength: 0)
            if let page = browser.selectedPage, page.zoom != 1 {
                Button("\(Int(page.zoom * 100))%") { page.zoom = 1 }.buttonStyle(.plain).help("Reset page zoom")
            }
            Button { Task { await browser.annotate() } } label: { Image(systemName: "bubble.left") }
                .buttonStyle(.plain).disabled(browser.selectedPage?.url == nil).help("Comment on an element")
            Button { Task { await browser.attachFeedback() } } label: { Image(systemName: "camera") }
                .buttonStyle(.plain).disabled(browser.selectedPage?.url == nil || browser.isCapturing).help("Attach screenshot to chat")
            Button {
                guard let url = browser.selectedPage?.url else { return }
                if url.isFileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                else { NSWorkspace.shared.open(url) }
            } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.plain).disabled(browser.selectedPage?.url == nil).help("Open in your default browser")
        }
    }

    private func historyMenu(backwards: Bool) -> some View {
        let list = browser.selectedPage?.webView.backForwardList
        let items = backwards ? Array((list?.backList ?? []).reversed()) : list?.forwardList ?? []
        return ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            Button(item.title ?? item.url.absoluteString) { browser.selectedPage?.webView.go(to: item) }
        }
    }

    private func locationRow(_ location: BrowserLocation) -> some View {
        HStack(spacing: 10) {
            siteIcon(location.url).frame(width: 24, height: 24).background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(location.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(location.url.absoluteString).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if browser.library.isBookmarked(location.url) { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
        }.contentShape(Rectangle())
    }

    private func siteIcon(_ url: URL?) -> some View {
        Group {
            if let host = url?.host, let first = host.replacingOccurrences(of: "www.", with: "").first {
                Text(String(first).uppercased()).font(.system(size: 11, weight: .semibold, design: .rounded))
            } else { Image(systemName: url?.isFileURL == true ? "doc.text" : "globe").font(.system(size: 12)) }
        }.foregroundStyle(.secondary)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12)).frame(width: 27, height: 28).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    private var securitySymbol: String {
        guard let url = browser.selectedPage?.url else { return "magnifyingglass" }
        if url.isFileURL { return "doc.text" }
        return url.scheme == "https" ? "lock" : "info.circle"
    }

    private var siteDescription: String {
        guard let url = browser.selectedPage?.url else { return "Search with DuckDuckGo or enter a website address." }
        if url.isFileURL { return "A local file inside this project." }
        return url.scheme == "https" ? "The connection to this site is encrypted with HTTPS." : "This page uses HTTP. The connection is not encrypted."
    }

    private func syncAddress() { address = browser.selectedPage?.url?.absoluteString ?? "" }
    private func focusFind() {
        addressFocused = false
        showsFind = true
        DispatchQueue.main.async { findFocused = true }
    }
    private func focusAddress() {
        syncAddress()
        addressFocused = true
        DispatchQueue.main.async {
            addressFocused = true
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }
    private func closeFind() {
        showsFind = false; findFocused = false
        browser.selectedPage?.findText = ""; browser.selectedPage?.find()
        if let view = browser.selectedPage?.webView { view.window?.makeFirstResponder(view) }
    }
    private func open(_ text: String) {
        addressFocused = false
        browser.navigate(text)
        syncAddress()
        if let view = browser.selectedPage?.webView { view.window?.makeFirstResponder(view) }
    }
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        panel.directoryURL = browser.root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url.absoluteString)
    }
}

private struct BrowserWebView: NSViewRepresentable {
    let page: BrowserPage
    let isActive: Bool
    func makeNSView(context: Context) -> WKWebView { page.webView }
    func updateNSView(_ view: WKWebView, context: Context) { view.isHidden = !isActive }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 1000, height: proposal.height ?? 700)
    }
}
