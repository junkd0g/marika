import AppKit
import MarikaCore
import SwiftUI
import UniformTypeIdentifiers

struct DeliverablePreview: View {
    let value: Deliverable
    @State private var slide = 0
    @State private var sheet = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(value.kind.rawValue.capitalized, systemImage: value.kind == .presentation ? "rectangle.on.rectangle" : value.kind == .spreadsheet ? "tablecells" : "doc.richtext")
                Spacer()
                DeliverableExportButton(value: value, sheet: sheet)
            }
            switch value.kind {
            case .report: MarkdownView(text: value.body ?? "").textSelection(.enabled)
            case .presentation: presentation
            case .spreadsheet: spreadsheet
            }
            if let sources = value.sources, !sources.isEmpty {
                DisclosureGroup("Sources (\(sources.count))") {
                    ForEach(sources) { source in
                        if let url = URL(string: source.url) { Link(source.title, destination: url) }
                        Text(source.excerpt).font(.caption).textSelection(.enabled)
                    }
                }
            }
        }
    }
    @ViewBuilder private var presentation: some View {
        if let slides = value.slides, !slides.isEmpty {
            let index = min(slide, slides.count - 1), current = slides[index]
            HStack {
                Button("Previous", systemImage: "chevron.left") { slide = max(0, index - 1) }.disabled(index == 0)
                Spacer(); Text("Slide \(index + 1) of \(slides.count)").font(.caption); Spacer()
                Button("Next", systemImage: "chevron.right") { slide = min(slides.count - 1, index + 1) }.disabled(index + 1 == slides.count)
            }.controlSize(.small)
            VStack(alignment: .leading, spacing: 22) {
                Text(current.title).font(.system(size: 26, weight: .bold))
                ForEach(Array(current.bullets.enumerated()), id: \.offset) { _, bullet in HStack(alignment: .top, spacing: 10) { Text("•"); Text(bullet) }.font(.system(size: 17)) }
                Spacer(minLength: 8)
            }.padding(30).frame(maxWidth: .infinity, minHeight: 290, alignment: .topLeading).background(Theme.canvas, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline) }.textSelection(.enabled)
            if let notes = current.notes, !notes.isEmpty { DisclosureGroup("Speaker notes") { Text(notes).textSelection(.enabled) } }
        }
    }
    @ViewBuilder private var spreadsheet: some View {
        if let sheets = value.sheets, !sheets.isEmpty {
            let index = min(sheet, sheets.count - 1), current = sheets[index]
            Picker("Sheet", selection: $sheet) { ForEach(sheets.indices, id: \.self) { index in Text(sheets[index].name).tag(index) } }.fixedSize()
            Text("\(current.rows.count) rows · \(current.columns.count) columns · Literal text cells").font(.caption).foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    gridRow(current.columns, header: true)
                    ForEach(Array(current.rows.enumerated()), id: \.offset) { _, row in gridRow(row, header: false) }
                }
            }.frame(height: 320).border(Theme.hairline)
            Text("XLSX exports include every sheet. CSV exports the selected sheet and protects formula-like text from execution.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func gridRow(_ cells: [String], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(cell).font(.system(size: 12, weight: header ? .semibold : .regular)).textSelection(.enabled)
                    .frame(width: 160, alignment: .leading).padding(9).frame(maxHeight: .infinity, alignment: .topLeading)
                    .background(header ? Theme.surface : Theme.canvas).border(Theme.hairline, width: 0.5)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

struct DeliverableExportButton: View {
    let value: Deliverable
    var sheet = 0
    @State private var exporting = false
    @State private var error: String?
    @State private var exported: URL?
    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Menu(exporting ? "Exporting…" : "Export") { ForEach(DeliverableExport.formats(for: value), id: \.self) { format in
                Button(format.rawValue.uppercased() + (format == .csv ? " · selected sheet" : "")) { export(format) }
            } }.disabled(exporting)
            if let error { Text(error).font(.caption).foregroundStyle(Theme.attention).textSelection(.enabled) }
            if let exported { Button("Show exported file") { NSWorkspace.shared.activateFileViewerSelecting([exported]) }.buttonStyle(.link).font(.caption) }
        }
    }
    private func export(_ format: DeliverableExport.Format) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(value.title.map { "/\\:".contains($0) ? "-" : $0 }.prefix(90)) + "." + format.rawValue
        panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true; error = nil
        Task {
            defer { exporting = false }
            do {
                let value = value, sheet = sheet
                try await Task.detached { try DeliverableExport.data(value, format: format, sheet: sheet).write(to: url, options: .atomic) }.value
                exported = url
            } catch { self.error = error.localizedDescription }
        }
    }
}
