import CoreGraphics
import CoreText
import Foundation

public enum DeliverableExport {
    public enum Format: String, CaseIterable, Sendable { case pdf, markdown = "md", html, csv, xlsx, pptx, json }
    public static func formats(for value: Deliverable) -> [Format] {
        switch value.kind { case .report: [.pdf, .markdown, .html, .json]; case .spreadsheet: [.xlsx, .csv, .html, .json]; case .presentation: [.pptx, .pdf, .html, .markdown, .json] }
    }
    public static func data(_ value: Deliverable, format: Format, sheet: Int = 0) throws -> Data {
        try value.validate()
        guard formats(for: value).contains(format) else { throw AgentError.launchFailed("Choose a format supported by this deliverable.") }
        switch format {
        case .json: let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return try encoder.encode(value)
        case .markdown: return Data(value.markdown.utf8)
        case .html: return Data(html(value).utf8)
        case .csv:
            guard let sheets = value.sheets, sheets.indices.contains(sheet) else { throw AgentError.launchFailed("Choose a sheet to export.") }
            return Data(csv(sheets[sheet]).utf8)
        case .pdf: return try pdf(value)
        case .xlsx: return archive(workbook(value))
        case .pptx: return archive(presentation(value))
        }
    }
    private static func escape(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value >= 32 || [9, 10, 13].contains($0.value) })
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    public static func csv(_ sheet: DeliverableSheet) -> String {
        ([sheet.columns] + sheet.rows).map { row in row.map { value in
            // Imported spreadsheet programs must treat agent output as text, including formulas.
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let safe = trimmed.first.map { "=+-@".contains($0) } == true || value.first == "\t" || value.first == "\r" ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }.joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
    public static func html(_ value: Deliverable) -> String {
        var body = "<h1>" + escape(value.title) + "</h1>"
        switch value.kind {
        case .report: body += MarkdownParser.parse(value.body ?? "").map { block in
            switch block {
            case .heading(let level, let text): return "<h\(level)>" + escape(text) + "</h\(level)>"
            case .paragraph(let text): return "<p>" + escape(text).replacingOccurrences(of: "\n", with: "<br>") + "</p>"
            case .code(_, let text): return "<pre><code>" + escape(text) + "</code></pre>"
            case .quote(let text): return "<blockquote>" + escape(text) + "</blockquote>"
            case .list(let items): return "<ul>" + items.map { "<li>" + escape($0.text) + "</li>" }.joined() + "</ul>"
            case .table(let header, let rows): return "<table><thead><tr>" + header.map { "<th>" + escape($0) + "</th>" }.joined() + "</tr></thead><tbody>" + rows.map { "<tr>" + $0.map { "<td>" + escape($0) + "</td>" }.joined() + "</tr>" }.joined() + "</tbody></table>"
            case .rule: return "<hr>"
            case .image(let alt, let source): return "<p>" + escape(alt + " — " + source) + "</p>"
            }
        }.joined(separator: "\n")
        case .presentation:
            for slide in value.slides ?? [] {
                body += "<section class=slide><h2>" + escape(slide.title) + "</h2><ul>" + slide.bullets.map { "<li>" + escape($0) + "</li>" }.joined() + "</ul>"
                if let notes = slide.notes { body += "<aside>" + escape(notes) + "</aside>" }
                body += "</section>"
            }
        case .spreadsheet:
            for sheet in value.sheets ?? [] {
                body += "<h2>" + escape(sheet.name) + "</h2><table><thead><tr>" + sheet.columns.map { "<th>" + escape($0) + "</th>" }.joined() + "</tr></thead><tbody>"
                body += sheet.rows.map { "<tr>" + $0.map { "<td>" + escape($0) + "</td>" }.joined() + "</tr>" }.joined() + "</tbody></table>"
            }
        }
        if let sources = value.sources, !sources.isEmpty { body += "<h2>Sources</h2><ul>" + sources.map { "<li>" + escape($0.title + " — " + $0.url + " — " + $0.excerpt) + "</li>" }.joined() + "</ul>" }
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'"><title>\(escape(value.title))</title><style>body{font:18px system-ui;max-width:1100px;margin:40px auto;padding:24px;color:#172333}h1,h2{line-height:1.2}pre{white-space:pre-wrap;font:inherit;line-height:1.6}.slide{padding:50px;border:1px solid #ccd4df;min-height:420px;margin:30px 0;break-after:page}li{margin:16px 0}aside{font-size:14px;color:#536174;white-space:pre-wrap}table{border-collapse:collapse;width:100%;overflow-wrap:anywhere}td,th{border:1px solid #ccd4df;padding:10px;text-align:left}th{background:#eef3fa}@media print{body{margin:0}.slide{border:0}}</style></head><body>\(body)</body></html>
        """
    }
    private static func pdf(_ value: Deliverable) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { throw AgentError.launchFailed("Couldn't create the PDF.") }
        var box = CGRect(x: 0, y: 0, width: value.kind == .presentation ? 960 : 595, height: value.kind == .presentation ? 540 : 842)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw AgentError.launchFailed("Couldn't create the PDF.") }
        let contents: [NSAttributedString]
        if value.kind == .presentation {
            contents = (value.slides ?? []).map { slide in
                let text = NSMutableAttributedString(string: "")
                append(slide.title, size: 30, bold: true, to: text)
                for bullet in slide.bullets { append("• " + bullet, size: 20, to: text) }
                if let notes = slide.notes { append("Notes: " + notes, size: 12, to: text) }
                return text
            } + sourceText(value).map { text in let result = NSMutableAttributedString(string: ""); append(text, size: 14, to: result); return result }
        } else {
            let text = NSMutableAttributedString(string: "")
            append(value.title, size: 24, bold: true, to: text)
            for block in MarkdownParser.parse(value.body ?? "") {
                switch block {
                case .heading(let level, let content): append(content, size: max(13, 23 - CGFloat(level) * 2), bold: true, to: text)
                case .paragraph(let content), .quote(let content): append(content, size: 12, to: text)
                case .code(_, let content): append(content, size: 10, monospaced: true, to: text)
                case .list(let items): for item in items { append(String(repeating: "  ", count: min(6, item.depth)) + "• " + item.text, size: 12, to: text) }
                case .table(let header, let rows): for row in [header] + rows { append(row.joined(separator: " | "), size: 10, monospaced: true, to: text) }
                case .rule: append("────────────────────", size: 10, to: text)
                case .image(let alt, let source): append(alt + " — " + source, size: 10, to: text)
                }
            }
            for sources in sourceText(value) { append(sources, size: 10, to: text) }
            contents = [text]
        }
        for string in contents {
            let setter = CTFramesetterCreateWithAttributedString(string)
            var offset = 0
            repeat {
                context.beginPDFPage(nil)
                let path = CGPath(rect: box.insetBy(dx: 44, dy: 40), transform: nil)
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: offset, length: 0), path, nil)
                CTFrameDraw(frame, context)
                let visible = CTFrameGetVisibleStringRange(frame); offset += visible.length
                context.endPDFPage()
                if visible.length == 0 { break }
            } while offset < string.length
        }
        context.closePDF(); return data as Data
    }
    private static func append(_ content: String, size: CGFloat, bold: Bool = false, monospaced: Bool = false, to output: NSMutableAttributedString) {
        let font = CTFontCreateWithName((monospaced ? "Menlo" : bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        output.append(NSAttributedString(string: content + "\n\n", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
    }
    private static func sourceText(_ value: Deliverable) -> [String] {
        guard let sources = value.sources, !sources.isEmpty else { return [] }
        return ["Sources\n\n" + sources.map { $0.title + "\n" + $0.url + "\n" + $0.excerpt }.joined(separator: "\n\n")]
    }
    private static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
    private static let relNS = "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let office = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    private static func relationships(_ items: [(String, String, String)]) -> String {
        declaration + "<Relationships xmlns=\"\(relNS)\">" + items.map { "<Relationship Id=\"\($0.0)\" Type=\"\(office)\($0.1)\" Target=\"\(escape($0.2))\"/>" }.joined() + "</Relationships>"
    }
    private static func types(_ overrides: [(String, String)]) -> String {
        declaration + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>" + overrides.map { "<Override PartName=\"/\($0.0)\" ContentType=\"application/vnd.openxmlformats-officedocument.\($0.1)+xml\"/>" }.joined() + "</Types>"
    }
    private static func workbook(_ value: Deliverable) -> [String: String] {
        var sheets = value.sheets ?? []
        if let sources = value.sources, !sources.isEmpty {
            var name = "Sources", suffix = 1
            while sheets.contains(where: { $0.name.lowercased() == name.lowercased() }) { suffix += 1; name = "Sources \(suffix)" }
            sheets.append(DeliverableSheet(name: name, columns: ["Source", "URL", "Evidence"], rows: sources.map { [$0.title, $0.url, $0.excerpt] }))
        }
        var files = ["_rels/.rels": relationships([("rId1", "officeDocument", "xl/workbook.xml")])]
        files["[Content_Types].xml"] = types([("xl/workbook.xml", "spreadsheetml.sheet.main")] + sheets.indices.map { ("xl/worksheets/sheet\($0 + 1).xml", "spreadsheetml.worksheet") })
        files["xl/workbook.xml"] = declaration + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"\(office.dropLast())\"><sheets>" + sheets.enumerated().map { "<sheet name=\"\(escape($0.element.name))\" sheetId=\"\($0.offset + 1)\" r:id=\"rId\($0.offset + 1)\"/>" }.joined() + "</sheets></workbook>"
        files["xl/_rels/workbook.xml.rels"] = relationships(sheets.indices.map { ("rId\($0 + 1)", "worksheet", "worksheets/sheet\($0 + 1).xml") })
        for (index, sheet) in sheets.enumerated() {
            let rows = ([sheet.columns] + sheet.rows).enumerated().map { number, cells in
                "<row r=\"\(number + 1)\">" + cells.map { "<c t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escape($0))</t></is></c>" }.joined() + "</row>"
            }.joined()
            files["xl/worksheets/sheet\(index + 1).xml"] = declaration + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(rows)</sheetData></worksheet>"
        }
        return files
    }
    private static func presentation(_ value: Deliverable) -> [String: String] {
        var slides = value.slides ?? []
        if let sources = value.sources, !sources.isEmpty {
            for start in stride(from: 0, to: sources.count, by: 4) {
                let group = Array(sources[start..<min(sources.count, start + 4)])
                slides.append(DeliverableSlide(title: "Sources", bullets: group.map { $0.title + " — " + $0.url }, notes: group.map(\.excerpt).joined(separator: "\n\n")))
            }
        }
        var files = ["_rels/.rels": relationships([("rId1", "officeDocument", "ppt/presentation.xml")])]
        let noteTypes = slides.indices.filter { slides[$0].notes?.isEmpty == false }.map { ("ppt/notesSlides/notesSlide\($0 + 1).xml", "presentationml.notesSlide") }
        files["[Content_Types].xml"] = types([("ppt/presentation.xml", "presentationml.presentation.main"), ("ppt/slideMasters/slideMaster1.xml", "presentationml.slideMaster"), ("ppt/slideLayouts/slideLayout1.xml", "presentationml.slideLayout")] + slides.indices.map { ("ppt/slides/slide\($0 + 1).xml", "presentationml.slide") } + noteTypes)
        files["ppt/presentation.xml"] = declaration + "<p:presentation xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\" xmlns:r=\"\(office.dropLast())\"><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rMaster\"/></p:sldMasterIdLst><p:sldIdLst>" + slides.indices.map { "<p:sldId id=\"\($0 + 256)\" r:id=\"rId\($0 + 1)\"/>" }.joined() + "</p:sldIdLst><p:sldSz cx=\"12192000\" cy=\"6858000\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>"
        files["ppt/_rels/presentation.xml.rels"] = relationships([("rMaster", "slideMaster", "slideMasters/slideMaster1.xml")] + slides.indices.map { ("rId\($0 + 1)", "slide", "slides/slide\($0 + 1).xml") })
        let group = "<p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree>"
        files["ppt/slideMasters/slideMaster1.xml"] = declaration + "<p:sldMaster xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\" xmlns:r=\"\(office.dropLast())\"><p:cSld>\(group)</p:cSld><p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/><p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rLayout\"/></p:sldLayoutIdLst></p:sldMaster>"
        files["ppt/slideMasters/_rels/slideMaster1.xml.rels"] = relationships([("rLayout", "slideLayout", "../slideLayouts/slideLayout1.xml")])
        files["ppt/slideLayouts/slideLayout1.xml"] = declaration + "<p:sldLayout xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\" type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\">\(group)</p:cSld></p:sldLayout>"
        files["ppt/slideLayouts/_rels/slideLayout1.xml.rels"] = relationships([("rMaster", "slideMaster", "../slideMasters/slideMaster1.xml")])
        for (index, slide) in slides.enumerated() {
            var rels = [("rLayout", "slideLayout", "../slideLayouts/slideLayout1.xml")]
            if let notes = slide.notes, !notes.isEmpty {
                rels.append(("rNotes", "notesSlide", "../notesSlides/notesSlide\(index + 1).xml"))
                files["ppt/notesSlides/_rels/notesSlide\(index + 1).xml.rels"] = relationships([("rSlide", "slide", "../slides/slide\(index + 1).xml")])
                files["ppt/notesSlides/notesSlide\(index + 1).xml"] = declaration + """
                <p:notes xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id="2" name="Notes"/><p:cNvSpPr/><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>\(escape(notes))</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:notes>
                """
            }
            files["ppt/slides/_rels/slide\(index + 1).xml.rels"] = relationships(rels)
            let text = [slide.title] + slide.bullets.map { "• " + $0 }
            let paragraphs = text.enumerated().map { row, content in "<a:p><a:r><a:rPr lang=\"en-US\" sz=\"\(row == 0 ? 3200 : 1800)\"/><a:t>\(escape(content))</a:t></a:r></a:p>" }.joined()
            files["ppt/slides/slide\(index + 1).xml"] = declaration + """
            <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id="2" name="Slide content"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="600000" y="400000"/><a:ext cx="10992000" cy="6058000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr wrap="square"><a:spAutoFit/></a:bodyPr><a:lstStyle/>\(paragraphs)</p:txBody></p:sp></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
            """
        }
        return files
    }
    /// A stored ZIP archive keeps exports self-contained and requires no installed office tools.
    private static func archive(_ files: [String: String]) -> Data {
        var output = Data(), directory = Data()
        func number<T: FixedWidthInteger>(_ value: T, to data: inout Data) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        for name in files.keys.sorted() {
            let path = Data(name.utf8), body = Data(files[name]!.utf8), offset = UInt32(output.count)
            var crc: UInt32 = 0xffffffff
            for byte in body { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) } }; crc ^= 0xffffffff
            number(UInt32(0x04034b50), to: &output); number(UInt16(20), to: &output)
            for field: UInt16 in [0, 0, 0, 0] { number(field, to: &output) }
            number(crc, to: &output); number(UInt32(body.count), to: &output); number(UInt32(body.count), to: &output)
            number(UInt16(path.count), to: &output); number(UInt16(0), to: &output); output.append(path); output.append(body)
            number(UInt32(0x02014b50), to: &directory); number(UInt16(20), to: &directory); number(UInt16(20), to: &directory)
            for field: UInt16 in [0, 0, 0, 0] { number(field, to: &directory) }
            number(crc, to: &directory); number(UInt32(body.count), to: &directory); number(UInt32(body.count), to: &directory); number(UInt16(path.count), to: &directory)
            for _ in 0..<4 { number(UInt16(0), to: &directory) }; number(UInt32(0), to: &directory); number(offset, to: &directory); directory.append(path)
        }
        let offset = UInt32(output.count); output.append(directory)
        number(UInt32(0x06054b50), to: &output); number(UInt16(0), to: &output); number(UInt16(0), to: &output)
        number(UInt16(files.count), to: &output); number(UInt16(files.count), to: &output); number(UInt32(directory.count), to: &output); number(offset, to: &output); number(UInt16(0), to: &output)
        return output
    }
}
