import MarikaCore
import SwiftUI
import WebKit

struct BrowserLibraryView: View {
    @Bindable var browser: BrowserWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var editing: BrowserLocation?
    @State private var pendingData: [WKWebsiteDataRecord] = []
    @State private var confirmsDataRemoval = false
    @State private var confirmsHistoryRemoval = false

    private var locations: [BrowserLocation] { browser.library.search(query, bookmarksOnly: browser.librarySection == "Bookmarks") }
    private var records: [WKWebsiteDataRecord] {
        browser.websiteRecords.filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Browser Library").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Section", selection: $browser.librarySection) {
                Text("History").tag("History")
                Text("Bookmarks").tag("Bookmarks")
                Text("Website Data").tag("Website Data")
            }.pickerStyle(.segmented)
            TextField("Search \(browser.librarySection.lowercased())", text: $query).textFieldStyle(.roundedBorder)
            if browser.librarySection == "Website Data" { websiteData }
            else { savedLocations }
            HStack {
                Text("Saved only for this project.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if browser.librarySection == "History" {
                    Button("Clear History…", role: .destructive) { confirmsHistoryRemoval = true }
                        .disabled(browser.library.history.isEmpty)
                } else if browser.librarySection == "Website Data" {
                    Button("Remove All Website Data…", role: .destructive) {
                        pendingData = browser.websiteRecords; confirmsDataRemoval = true
                    }.disabled(browser.websiteRecords.isEmpty || browser.isClearingWebsiteData)
                }
            }
        }
        .padding(20).frame(width: 590, height: 480).background(Theme.canvas)
        .task { await browser.refreshWebsiteData() }
        .onChange(of: browser.librarySection) { _, _ in query = "" }
        .sheet(item: $editing) { BookmarkEditor(browser: browser, location: $0) }
        .confirmationDialog("Remove website data?", isPresented: $confirmsDataRemoval, titleVisibility: .visible) {
            Button("Remove Data", role: .destructive) { Task { await browser.removeWebsiteData(pendingData); pendingData = [] } }
            Button("Cancel", role: .cancel) { pendingData = [] }
        } message: {
            Text("This removes cookies, cached files and local storage for \(pendingData.count) site(s) in this project. You may be signed out. Open pages can save new data.")
        }
        .confirmationDialog("Clear this project's browsing history?", isPresented: $confirmsHistoryRemoval, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { browser.library.clearHistory() }
        } message: { Text("Bookmarks, cookies and open tabs will be kept.") }
    }

    private var savedLocations: some View {
        List(locations) { location in
            HStack(spacing: 10) {
                Image(systemName: browser.librarySection == "Bookmarks" ? "star" : "clock").foregroundStyle(.secondary)
                Button {
                    browser.navigate(location.url.absoluteString)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(location.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(location.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if browser.librarySection == "Bookmarks" {
                    Button { editing = location } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless).accessibilityLabel("Edit bookmark \(location.title)")
                }
                Button {
                    if browser.librarySection == "Bookmarks" { browser.library.removeBookmark(location.url) }
                    else { browser.library.removeHistory(location.url) }
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).accessibilityLabel("Remove \(location.title)")
            }.padding(.vertical, 5).accessibilityElement(children: .contain)
        }
        .overlay { if locations.isEmpty { ContentUnavailableView(query.isEmpty ? "Nothing saved yet" : "No matches", systemImage: "magnifyingglass") } }
    }

    private var websiteData: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cookies, caches and local storage. Removing a site can sign you out.").font(.caption).foregroundStyle(.secondary)
            List(records, id: \.displayName) { record in
                HStack {
                    Image(systemName: "globe").foregroundStyle(.secondary)
                    Text(record.displayName)
                    Spacer()
                    Button("Remove…", role: .destructive) { pendingData = [record]; confirmsDataRemoval = true }
                        .buttonStyle(.borderless).accessibilityLabel("Remove data for \(record.displayName)")
                        .disabled(browser.isClearingWebsiteData)
                }.padding(.vertical, 6)
            }
            .overlay { if records.isEmpty { ContentUnavailableView("No website data", systemImage: "externaldrive") } }
        }
    }
}

private struct BookmarkEditor: View {
    let browser: BrowserWorkspace
    let location: BrowserLocation
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var address = ""
    @State private var error: String?

    var body: some View {
        Form {
            Text("Edit Bookmark").font(.headline)
            TextField("Name", text: $title)
            TextField("Address", text: $address)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        let url = try BrowserAddress.resolve(address, projectRoot: browser.root)
                        browser.library.editBookmark(location.url, title: title, url: url)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 420)
        .onAppear { title = location.title; address = location.url.absoluteString }
    }
}
