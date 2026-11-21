import Foundation
import Testing
@preconcurrency import WebKit
@testable import MarikaCore

@MainActor
struct QABrowserActionTests {
    @Test func browserActionsDoNotInventSuccessForUnusableControls() async throws {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        defer { view.stopLoading() }
        view.loadHTMLString("""
        <html><body id="ready">
        <button id="disabled" disabled>Locked</button>
        <fieldset disabled><button id="fieldset-button">Disabled by fieldset</button></fieldset>
        <input id="readonly" readonly value="original">
        <select id="options"><option value="a">Alpha</option><option value="b" disabled>Beta</option></select>
        <input id="radio" type="radio" checked>
        <input id="cancelled" type="checkbox" onclick="event.preventDefault()">
        <button id="target" onclick="this.textContent='Clicked'">Click me</button>
        <div id="overlay" style="position:fixed;inset:0;z-index:100;background:white">Cover</div>
        </body></html>
        """, baseURL: nil)
        var loaded = false
        for _ in 0..<100 {
            if (try? await evaluate("return !!document.getElementById('ready');", in: view))?.bool == true { loaded = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(loaded)

        let visible = try await evaluate(QABrowserActions.script(QAAction(.assertVisible, selector: "#disabled")), in: view)
        #expect(visible["ready"]?.bool == true)
        let text = try await evaluate(QABrowserActions.script(QAAction(.assertText, selector: "#disabled", value: "Locked")), in: view)
        #expect(text["ready"]?.bool == true)
        let disabledClick = try await evaluate(QABrowserActions.script(QAAction(.click, selector: "#disabled")), in: view)
        #expect(disabledClick["ready"]?.bool == false)
        let fieldsetClick = try await evaluate(QABrowserActions.script(QAAction(.click, selector: "#fieldset-button")), in: view)
        #expect(fieldsetClick["ready"]?.bool == false)
        let coveredClick = try await evaluate(QABrowserActions.script(QAAction(.click, selector: "#target")), in: view)
        #expect(coveredClick["ready"]?.bool == false)
        await #expect(throws: (any Error).self) {
            _ = try await evaluate(QABrowserActions.script(QAAction(.fill, selector: "#readonly", value: "changed")), in: view)
        }
        await #expect(throws: (any Error).self) {
            _ = try await evaluate(QABrowserActions.script(QAAction(.select, selector: "#options", value: "missing")), in: view)
        }
        await #expect(throws: (any Error).self) {
            _ = try await evaluate(QABrowserActions.script(QAAction(.select, selector: "#options", value: "b")), in: view)
        }
        await #expect(throws: (any Error).self) {
            _ = try await evaluate(QABrowserActions.script(QAAction(.check, selector: "#radio", value: "false")), in: view)
        }
        await #expect(throws: (any Error).self) {
            _ = try await evaluate(QABrowserActions.script(QAAction(.check, selector: "#cancelled", value: "true")), in: view)
        }
        #expect(try await evaluate("return document.getElementById('readonly').value;", in: view).string == "original")
        #expect(try await evaluate("return document.getElementById('options').value;", in: view).string == "a")
        _ = try await evaluate("document.getElementById('overlay').remove(); return true;", in: view)
        #expect(try await evaluate(QABrowserActions.script(QAAction(.click, selector: "#target")), in: view)["ready"]?.bool == true)
        #expect(try await evaluate("return document.getElementById('target').textContent;", in: view).string == "Clicked")
    }

    private func evaluate(_ script: String, in view: WKWebView) async throws -> JSONValue {
        let text: String = try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript("JSON.stringify((()=>{\(script)})())") { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value as? String ?? "null") }
            }
        }
        return try JSONValue(parsing: Data(text.utf8))
    }
}
