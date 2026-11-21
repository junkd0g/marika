import AppKit
import MarikaCore

struct DesignImportFidelity {
    let reference: Data
    let render: Data
    let difference: QAImages.Comparison

    @MainActor static func compare(_ reference: DesignImportReference, with document: DesignDocument) async throws -> Self {
        guard let path = reference.imagePath, reference.width > 0, reference.height > 0 else {
            throw DesignToolError("A saved reference screenshot is required.")
        }
        let (original, width, height) = try await Task.detached {
            let normalized = try QAImages.normalize(Data(contentsOf: URL(fileURLWithPath: path)))
            return (normalized.data, normalized.width, normalized.height)
        }.value
        let scale = Double(width) / reference.width
        // WebKit reports integer CSS sizes and independently rounds snapshot pixel dimensions.
        guard abs(scale * reference.height - Double(height)) <= 4 else {
            throw DesignToolError("The screenshot and measured viewport have different proportions.")
        }
        let render = try DesignRenderer.referencePNG(document: document, viewport: reference, pixels: CGSize(width: width, height: height))
        let difference = try await Task.detached { try QAImages.compare(baseline: original, actual: render) }.value
        return Self(reference: original, render: render, difference: difference)
    }
}
