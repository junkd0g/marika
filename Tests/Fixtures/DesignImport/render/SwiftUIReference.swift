import AppKit
import SwiftUI

@main struct SwiftUIReference {
    @MainActor static func main() throws {
        let screen = ZStack(alignment: .topLeading) {
            Color(red: 0.96, green: 0.96, blue: 0.98)
            WelcomeScreen()
        }.frame(width: 560, height: 380).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: screen)
        renderer.scale = 1
        guard let image = renderer.cgImage, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
