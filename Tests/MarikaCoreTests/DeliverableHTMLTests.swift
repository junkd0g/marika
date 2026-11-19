import Foundation
import Testing
@testable import MarikaCore

struct DeliverableHTMLTests {
    @Test func reportBlocksKeepTheirStructureAndEscapeUntrustedMarkup() {
        let body = """
        ## Heading <unsafe>

        Paragraph & text
        second line

        > Quote <unsafe>

        - Item <unsafe>

        | Column <unsafe> | Other |
        | --- | --- |
        | Cell & value | Final |

        ```html
        <script>alert("x")</script>
        ```

        ---

        ![Image <unsafe>](https://example.com/image.png)
        """
        let result = DeliverableExport.html(Deliverable(kind: .report, title: "Title & text", body: body))
        for fragment in ["<h1>Title &amp; text</h1>", "<h2>Heading &lt;unsafe&gt;</h2>",
                         "<p>Paragraph &amp; text<br>second line</p>", "<blockquote>Quote &lt;unsafe&gt;</blockquote>",
                         "<ul><li>Item &lt;unsafe&gt;</li></ul>", "<th>Column &lt;unsafe&gt;</th>",
                         "<td>Cell &amp; value</td>", "<pre><code>&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;</code></pre>",
                         "<hr>", "<p>Image &lt;unsafe&gt; — https://example.com/image.png</p>"] {
            #expect(result.contains(fragment), "Missing rendered block: \(fragment)")
        }
        #expect(!result.contains("<script>") && !result.contains("<img"))
        #expect(result.contains("default-src 'none'"))
    }

    @Test func spreadsheetTablesUseEscapedHeadersCellsAndSourceText() {
        let sheet = DeliverableSheet(name: "Data & notes", columns: ["<name>", "Value"], rows: [["<b>text</b>", "A&B"], ["Second", "=2+2"]])
        let source = ResearchSource(id: "one", title: "Source <title>", url: "https://example.com/?a=1&b=2", excerpt: "<unsafe>")
        let value = Deliverable(kind: .spreadsheet, title: "Table", sheets: [sheet], sources: [source])
        let result = DeliverableExport.html(value)
        #expect(result.contains("<h2>Data &amp; notes</h2><table><thead><tr><th>&lt;name&gt;</th><th>Value</th></tr></thead><tbody>"))
        #expect(result.contains("<tr><td>&lt;b&gt;text&lt;/b&gt;</td><td>A&amp;B</td></tr><tr><td>Second</td><td>=2+2</td></tr></tbody></table>"))
        #expect(result.contains("Source &lt;title&gt; — https://example.com/?a=1&amp;b=2 — &lt;unsafe&gt;"))
    }
}
