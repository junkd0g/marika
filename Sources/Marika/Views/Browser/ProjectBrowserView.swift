import AppKit
import MarikaCore
import SwiftUI
import WebKit

struct ProjectBrowserView: View {
    @Bindable var browser: BrowserWorkspace
    var isVisible: Bool
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            tabs
            Divider()
            navigation
            if let page = browser.selectedPage, page.isLoading {
                ProgressView(value: page.progress).progressViewStyle(.linear).controlSize(.mini)
            } else { Divider() }
            if let error = browser.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.attention)
                    Text(error).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { browser.errorMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss browser error")
                }
                .padding(12).background(Theme.attention.opacity(0.08))
            }
            if browser.annotation != nil { annotationForm }
            if browser.selectedPage?.isAnnotating == true {
                HStack {
                    Label("Click an element in the page to leave feedback.", systemImage: "cursorarrow")
                    Spacer()
                    Button("Cancel") { Task { await browser.annotate() } }
                }
                .font(.system(size: 12)).padding(10).background(Color.accentColor.opacity(0.08))
            }
            GeometryReader { geometry in
                let width = min(geometry.size.width, browser.viewport == "Mobile" ? 390 : browser.viewport == "Tablet" ? 768 : geometry.size.width)
                ZStack {
                    Theme.surface
                    ForEach(browser.pages) { page in
                        BrowserWebView(page: page, isActive: isVisible && page.id == browser.selectedPageID)
                            .frame(width: width, height: geometry.size.height)
                            .clipped()
                            .opacity(page.id == browser.selectedPageID ? 1 : 0)
                            .allowsHitTesting(page.id == browser.selectedPageID)
                            .accessibilityHidden(page.id != browser.selectedPageID)
                    }
                    if browser.selectedPage?.url == nil {
                        VStack(spacing: 12) {
                            Image(systemName: "globe").font(.system(size: 32, weight: .light)).foregroundStyle(Color.accentColor)
                            Text("Preview your project").font(.system(size: 20, weight: .semibold))
                            Text("Open a local development URL, a project HTML file, or a website.")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                Button("localhost:3000") { open("http://localhost:3000") }
                                Button("Open HTML File…", action: chooseFile)
                            }
                            .controlSize(.small)
                            Text("Use Comment to attach visual feedback to your conversation.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.center).padding(30)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.canvas)
                    } else if let error = browser.selectedPage?.navigationError {
                        VStack(spacing: 12) {
                            Image(systemName: "wifi.exclamationmark").font(.system(size: 30)).foregroundStyle(.secondary)
                            Text("Couldn't load this page").font(.system(size: 18, weight: .semibold))
                            Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                            Text("For local previews, make sure your development server is running.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Button("Try Again") { browser.selectedPage?.webView.reload() }
                        }
                        .multilineTextAlignment(.center).padding(30)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.canvas)
                    }
                }
            }
            .clipped()
            Divider()
            footer
        }
        .background(Theme.canvas)
        .onAppear { address = browser.selectedPage?.url?.absoluteString ?? "" }
        .onChange(of: browser.selectedPageID) { _, _ in address = browser.selectedPage?.url?.absoluteString ?? "" }
        .onChange(of: browser.selectedPage?.url) { _, url in
            if !addressFocused { address = url?.absoluteString ?? "" }
        }
        .onChange(of: isVisible) { _, visible in if !visible { addressFocused = false } }
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(browser.pages) { page in
                        HStack(spacing: 8) {
                            Button { browser.selectedPageID = page.id } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "globe").foregroundStyle(.secondary)
                                    Text(page.title).font(.system(size: 12)).lineLimit(1).frame(maxWidth: 170)
                                }.padding(.vertical, 11)
                            }
                            .buttonStyle(.plain)
                            Button { browser.close(page) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                                .buttonStyle(.plain).accessibilityLabel("Close browser tab \(page.title)")
                        }
                        .padding(.horizontal, 12)
                        .background(page.id == browser.selectedPageID ? Color.accentColor.opacity(0.08) : .clear)
                        .overlay(alignment: .bottom) {
                            if page.id == browser.selectedPageID { Color.accentColor.frame(height: 2) }
                        }
                        Divider()
                    }
                }
            }
            .scrollIndicators(.hidden)
            Button {
                browser.newPage()
                address = ""
                addressFocused = true
            } label: { Image(systemName: "plus").frame(width: 32, height: 32) }
            .buttonStyle(.plain).help("New browser tab").accessibilityLabel("New browser tab")
        }
        .frame(height: 36)
        .background(Theme.chrome.opacity(0.5))
    }

    private var navigation: some View {
        HStack(spacing: 12) {
            Button { browser.selectedPage?.webView.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(browser.selectedPage?.canGoBack != true).help("Back").accessibilityLabel("Back")
            Button { browser.selectedPage?.webView.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(browser.selectedPage?.canGoForward != true).help("Forward").accessibilityLabel("Forward")
            Button {
                if browser.selectedPage?.isLoading == true { browser.selectedPage?.webView.stopLoading() }
                else { browser.selectedPage?.webView.reload() }
            } label: { Image(systemName: browser.selectedPage?.isLoading == true ? "xmark" : "arrow.clockwise") }
                .disabled(browser.selectedPage?.url == nil).help("Reload or stop").accessibilityLabel("Reload or stop page")
            HStack(spacing: 7) {
                Image(systemName: browser.selectedPage?.url?.scheme == "https" ? "lock" : "globe").foregroundStyle(.secondary)
                TextField("URL, localhost:3000, or project HTML file", text: $address)
                    .textFieldStyle(.plain).font(.system(size: 12)).focused($addressFocused)
                    .onSubmit { open(address) }
                    .accessibilityLabel("Browser address")
            }
            .padding(8).background(Theme.canvas, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.hairline) }
            Button { Task { await browser.annotate() } } label: { Image(systemName: "bubble.left.and.text.bubble.right") }
                .disabled(browser.selectedPage?.url == nil).help("Comment on an element").accessibilityLabel("Comment on page")
            Button { Task { await browser.attachFeedback() } } label: { Image(systemName: "camera") }
                .disabled(browser.selectedPage?.url == nil || browser.isCapturing)
                .help("Attach page screenshot to your conversation draft").accessibilityLabel("Attach browser screenshot")
            Menu {
                Toggle("Allow agents on local previews", isOn: $browser.allowsLocalAgentAccess)
                if let url = browser.selectedPage?.url, !url.isFileURL, !BrowserAddress.isLocal(url) {
                    Toggle("Allow agents on \(url.host ?? "this site")", isOn: Binding(
                        get: { browser.allowedOrigins.contains(BrowserAddress.origin(url)) }, set: { value in browser.allowCurrentSite(value) }))
                }
                Divider()
                Text("Website content is shared only when an agent uses a browser tool or you attach feedback.")
            } label: {
                Image(systemName: browser.canUseAgent ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark")
                    .foregroundStyle(browser.canUseAgent ? Color.accentColor : .secondary)
            }
            .menuStyle(.borderlessButton).fixedSize().help("Agent access")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Theme.chrome.opacity(0.5))
    }

    private var annotationForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(browser.annotation?["selector"]?.string ?? "Selected element", systemImage: "cursorarrow.click")
                    .font(Theme.codeSmall).lineLimit(1)
                Spacer()
                Button {
                    browser.clearFeedback()
                } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Cancel browser comment")
            }
            HStack {
                TextField("What should change here?", text: $browser.comment)
                    .textFieldStyle(.roundedBorder)
                Button(browser.isCapturing ? "Capturing…" : "Add to Message") { Task { await browser.attachFeedback() } }
                    .disabled(browser.isCapturing || browser.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Includes the page URL, element, viewport, and a screenshot. Review your draft before sending.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .padding(12).background(Color.accentColor.opacity(0.07))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Picker("Viewport", selection: $browser.viewport) {
                Text("Desktop").tag("Desktop")
                Text("Tablet · 768").tag("Tablet")
                Text("Mobile · 390").tag("Mobile")
            }
            .labelsHidden().frame(width: 140).controlSize(.small)
            Text(browser.canUseAgent ? "Agent access on" : "Agent access off")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text("Right-click → Inspect Element").font(.system(size: 10.5)).foregroundStyle(.secondary)
            Button {
                guard let url = browser.selectedPage?.url else { return }
                if url.isFileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                else { NSWorkspace.shared.open(url) }
            } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.plain).disabled(browser.selectedPage?.url == nil).help("Open in your default browser")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private func open(_ text: String) {
        addressFocused = false
        browser.navigate(text)
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
