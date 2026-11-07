import MarikaCore
import SwiftUI

enum Theme {
    static let transcriptWidth: CGFloat = 760
    static let code = Font.system(size: 12, design: .monospaced)
    static let codeSmall = Font.system(size: 11, design: .monospaced)
    static let body = Font.system(size: 14)
    static let radius: CGFloat = 10

    static let addition = Color.green
    static let deletion = Color.red
    static let attention = Color.orange
    static let surface = Color.primary.opacity(0.04)
    static let hairline = Color.primary.opacity(0.10)
    static let canvas = adaptive(light: 0xFFFFFF, dark: 0x202020)
    static let panel = adaptive(light: 0xFAFAFA, dark: 0x272727)
    static let chrome = adaptive(light: 0xFAFAFA, dark: 0x1D1D1D)
    static let sidebar = adaptive(light: 0xF5F5F5, dark: 0x181818)
    static let composer = adaptive(light: 0xF9F9F9, dark: 0x292929)
    static let selection = Color.primary.opacity(0.07)
    static let messageBubble = adaptive(light: 0xF0F0F0, dark: 0x303030)
    static let ink = adaptive(light: 0x202020, dark: 0xEEEEEE)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
        })
    }

    @MainActor static let appIcon: NSImage? = {
        if let bundled = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            return NSImage(contentsOf: bundled)
        }
        #if DEBUG
            return NSImage(contentsOfFile: FileManager.default.currentDirectoryPath + "/Resources/AppIcon-preview.png")
        #else
            return nil
        #endif
    }()
}

extension View {
    /// A raised panel. Solid rather than glass: these hold diffs and text that must stay legible
    /// over a scrolling transcript, and it looks the same on every supported macOS.
    func floatingPanel(cornerRadius: CGFloat = 12) -> some View {
        background(Theme.panel, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.hairline)
            }
            .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }

    func surface(cornerRadius: CGFloat = Theme.radius) -> some View {
        background(Theme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

enum Format {
    static func duration(milliseconds: Int) -> String {
        duration(seconds: Double(milliseconds) / 1000)
    }

    static func duration(seconds: Double) -> String {
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)s" }
        let minutes = whole / 60
        if minutes < 60 { return "\(minutes)m \(whole % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return "\(count / 1_000)k" }
        return "\(count)"
    }

    /// Effort levels as people say them.
    static func effort(_ level: String) -> String {
        level == "xhigh" ? "Extra High" : level.capitalized
    }

    static func cost(_ usd: Double) -> String {
        usd < 0.01 ? String(format: "$%.4f", usd) : String(format: "$%.2f", usd)
    }

    /// Compact age for lists: "now", "5m", "3h", "2d".
    static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }

    static func reset(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        if Calendar.current.isDateInToday(date) {
            formatter.setLocalizedDateFormatFromTemplate("jm")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("E jm")
        }
        return formatter.string(from: date)
    }
}

extension ToolCall {
    /// The agent loading its own tools. True, but nothing the user needs to read.
    var isInternal: Bool { name == "ToolSearch" }

    var symbol: String {
        switch kind {
        case .shell: "terminal"
        case .read: "doc.text"
        case .edit: "pencil"
        case .write: "doc.badge.plus"
        case .search: "magnifyingglass"
        case .web: "globe"
        case .subagent: "person.2"
        case .todo: "checklist"
        case .question: "questionmark.bubble"
        case .plan: "list.bullet.clipboard"
        case .mcp: "puzzlepiece.extension"
        case .skill: "wand.and.stars"
        case .other: "wrench.and.screwdriver"
        }
    }
}

/// A small button that copies text and briefly confirms it.
struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 11))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Copy")
    }
}
