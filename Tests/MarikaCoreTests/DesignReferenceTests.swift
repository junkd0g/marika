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

    @Test func duplicateLabelsRequireSeparateEditableLayersInViewport() {
        let sample = DesignReferenceElement(text: "Open", x: 20, y: 40, width: 80, height: 40, color: "", fontSize: 16)
        let reference = DesignImportReference(source: "Local preview", width: 400, height: 300, elements: [sample, sample])
        var document = DesignDocument()
        let visible = document.add(.rectangle, in: CGRect(x: 20, y: 40, width: 80, height: 40))
        let outside = document.add(.text, in: CGRect(x: 500, y: 40, width: 80, height: 40))
        document.update([visible, outside]) { $0.text = "Open" }
        let comparison = DesignReferenceComparison(reference: reference, document: document)
        #expect(comparison.matched == 1)
        #expect(comparison.missingText == ["Open"])
        #expect(comparison.unlinkedText == ["Open"])
        #expect(comparison.meanSizeError == 0)
    }
}
