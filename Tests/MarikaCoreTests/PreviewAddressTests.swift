import Foundation
import Testing
@testable import MarikaCore

struct PreviewAddressTests {
    @Test(arguments: [
        ("Serving HTTP on 127.0.0.1 port 8000 (http://127.0.0.1:8000/) ...", "http://127.0.0.1:8000/"),
        ("Local: 'http://localhost:5173/'", "http://localhost:5173/"),
        ("Preview at <http://localhost:3000/app>.", "http://localhost:3000/app"),
        ("Open (http://localhost:3000/docs/(intro))", "http://localhost:3000/docs/(intro)"),
        ("Listening at http://0.0.0.0:8000/", "http://127.0.0.1:8000/"),
        ("Serving (http://[::]:8000/)", "http://localhost:8000/"),
    ])
    func consolePunctuationDoesNotBecomePartOfThePreviewURL(example: (String, String)) {
        #expect(ProjectPreview.detectedAddress(in: example.0)?.absoluteString == example.1)
    }
}
