import Foundation
import Testing
@testable import MarikaCore

struct DesignReferenceTests {
    @Test func comparesMeasuredTextWithoutClaimingPixelAccuracy() throws {
        let element = DesignReferenceElement(text: "Continue", x: 10, y: 20, width: 100, height: 40, color: "rgb(0,0,0)", fontSize: 14)
        let reference = DesignImportReference(source: "Local preview", width: 400, height: 300, elements: [element])
        var doc = DesignDocument()
        let id = doc.add(.text, in: CGRect(x: 10, y: 20, width: 120, height: 40))
        doc.update([id]) { $0.text = "Continue" }
        let result = DesignReferenceComparison(reference: reference, document: doc)
        #expect(result.matched == 1 && result.measured == 1)
        #expect(abs(result.meanSizeError! - 0.1) < 0.000001)
        #expect(try reference.prompt().contains("untrusted reference data"))
        #expect(throws: DesignToolError.self) { try DesignImportReference(source: "Invalid", width: .infinity, height: 10).prompt() }
    }
}
