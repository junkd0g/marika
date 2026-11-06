import AppKit
import MarikaCore
import PDFKit
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

struct FilePreviewView: View {
    let snapshot: FilePreviewSnapshot

    var body: some View {
        let type = UTType(filenameExtension: snapshot.url.pathExtension)
        Group {
            if type?.conforms(to: .pdf) == true {
                PDFFilePreview(snapshot: snapshot)
            } else if type?.conforms(to: .image) == true, type != .svg {
                ImageFilePreview(snapshot: snapshot)
            } else {
                QuickLookFilePreview(snapshot: snapshot)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}

private struct ImageFilePreview: View {
    let snapshot: FilePreviewSnapshot
    @State private var image: NSImage?
    @State private var loaded = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().padding(24)
            } else if loaded {
                ContentUnavailableView("Couldn't preview this image", systemImage: "photo",
                                       description: Text("The image may be damaged or use an unsupported format."))
            } else { ProgressView().controlSize(.small) }
        }
        .task(id: snapshot) {
            image = NSImage(contentsOf: snapshot.url)
            loaded = true
        }
    }
}

private struct PDFFilePreview: View {
    let snapshot: FilePreviewSnapshot
    @State private var document: PDFDocument?
    @State private var loaded = false

    var body: some View {
        Group {
            if let document {
                PDFDocumentView(document: document)
            } else if loaded {
                ContentUnavailableView("Couldn't preview this PDF", systemImage: "doc.badge.ellipsis",
                    description: Text("The file may be damaged or may not contain a valid PDF document."))
            } else { ProgressView().controlSize(.small) }
        }
        .task(id: snapshot) {
            document = PDFDocument(url: snapshot.url)
            loaded = true
        }
    }
}

private struct PDFDocumentView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = NSColor(Theme.canvas)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}

/// Use installed Quick Look extensions for SVG, media, and other supported file types.
private struct QuickLookFilePreview: NSViewRepresentable {
    let snapshot: FilePreviewSnapshot

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        view.shouldCloseWithWindow = false
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard context.coordinator.snapshot != snapshot else { return }
        let reloading = context.coordinator.snapshot?.url == snapshot.url
        view.previewItem = snapshot.url as NSURL
        if reloading { view.refreshPreviewItem() }
        context.coordinator.snapshot = snapshot
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) { view.close() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: QLPreviewView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: proposal.height ?? 400)
    }

    final class Coordinator {
        var snapshot: FilePreviewSnapshot?
    }
}
