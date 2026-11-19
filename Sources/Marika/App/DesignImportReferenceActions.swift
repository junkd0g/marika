import AppKit
import ImageIO
import MarikaCore
import UniformTypeIdentifiers

extension DesignImportModel {
    func capturePreview() async {
        guard let app, let project = app.project(id: projectID), let page = app.browsers[projectID]?.selectedPage,
              let url = page.url, (url.isFileURL && url.standardizedFileURL.path.hasPrefix(project.url.standardizedFileURL.path + "/")) || ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "") else {
            error = "Open a local project preview in Browser first, or attach a screenshot of the running app."; return
        }
        working = true; defer { working = false }
        do {
            let value = try await page.evaluate(Self.referenceScript)
            var ref = try JSONDecoder().decode(DesignImportReference.self, from: value.serialized())
            ref.source = "Local preview: " + (url.isFileURL ? url.lastPathComponent : (url.host ?? "") + url.path)
            _ = try ref.prompt()
            referenceImage = try await page.screenshot(); reference = ref; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func chooseReference() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 8_000_000,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16_777_216,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw DesignToolError("Choose a PNG or JPEG screenshot up to 8 MB and 16 megapixels.")
            }
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let png = bitmap.representation(using: .png, properties: [:]), png.count <= 8_000_000 else {
                throw DesignToolError("The converted screenshot exceeds 8 MB. Choose a smaller screenshot.")
            }
            reference = DesignImportReference(source: url.lastPathComponent, width: Double(bitmap.pixelsWide), height: Double(bitmap.pixelsHigh))
            referenceImage = png; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private static let referenceScript = #"""
        const elements = [...document.querySelectorAll('button,a,h1,h2,h3,p,label,span,input,textarea,select')]
          .filter(e => { const r=e.getBoundingClientRect(), s=getComputedStyle(e); return r.width>0 && r.height>0 && r.top>=0 && r.left>=0 && r.bottom<=innerHeight && r.right<=innerWidth && s.visibility!=='hidden' && s.display!=='none' && e.children.length===0; })
          .slice(0,40).map(e => { const r=e.getBoundingClientRect(),s=getComputedStyle(e);return {text:(e.innerText||e.getAttribute('placeholder')||'').trim().slice(0,100),x:r.x,y:r.y,width:r.width,height:r.height,color:s.color,fontSize:parseFloat(s.fontSize)||14}; });
        return {source:'Local preview',width:innerWidth,height:innerHeight,elements};
        """#
}
