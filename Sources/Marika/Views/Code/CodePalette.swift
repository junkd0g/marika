import AppKit
import MarikaCore

/// A coordinated editor palette, resolved against the view's actual appearance.
@MainActor enum CodePalette {
    static let font = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
    static let foreground = color(0xD4D4D4, 0x24292F)
    static let background = color(0x1E1E1E, 0xFFFFFF)
    static let gutter = color(0x1B1B1B, 0xF6F8FA)
    static let lineNumber = color(0x7D8590, 0x8C959F)
    static let selection = color(0x264F78, 0xADD6FF)
    static let activeLine = color(0xFFFFFF, 0x000000, alpha: 0.035)
    static let guide = color(0xFFFFFF, 0x24292F, alpha: 0.09)
    static let matchingBracket = color(0xADD6FF, 0x0969DA, alpha: 0.18)

    static func token(_ kind: CodeTokenKind) -> NSColor {
        switch kind {
        case .keyword: color(0xC586C0, 0xA626A4)
        case .type: color(0x4EC9B0, 0x267F99)
        case .function: color(0xDCDCAA, 0x795E26)
        case .string: color(0xCE9178, 0xA31515)
        case .number: color(0xB5CEA8, 0x098658)
        case .comment: color(0x7F9F7F, 0x587C4C)
        case .property, .variable: color(0x9CDCFE, 0x164E8C)
        case .constant: color(0x4FC1FF, 0x0070C1)
        case .attribute: color(0xD7BA7D, 0x795E26)
        case .tag: color(0x569CD6, 0x800000)
        case .punctuation: color(0xB8BEC9, 0x5C6370)
        }
    }
    static func paragraph(font: NSFont = font, tabWidth: Int = 4) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width * CGFloat(tabWidth)
        style.tabStops = []
        return style
    }
    private static func color(_ dark: UInt32, _ light: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
        }
    }
}
