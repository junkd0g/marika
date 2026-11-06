import AppKit
import Observation
import SwiftUI

enum EditorTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: "Automatic"; case .light: "Light"; case .dark: "Dark" } }
    var appearance: NSAppearance? {
        switch self { case .system: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) }
    }
}

struct EditorStyle: Equatable {
    var fontSize = 13.5
    var theme: EditorTheme = .system
    var tabWidth = 4
    var usesTabs = false
    var wrapsLines = false
    var showsIndentGuides = true
    @MainActor var font: NSFont { .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    @MainActor var paragraph: NSParagraphStyle { CodePalette.paragraph(font: font, tabWidth: tabWidth) }
    var indent: String { usesTabs ? "\t" : String(repeating: " ", count: tabWidth) }
}

@MainActor @Observable final class EditorSettings {
    #if DEBUG
    static let shared = EditorSettings(defaults: ProcessInfo.processInfo.environment["MARIKA_EDITOR_DEFAULTS_SUITE"].flatMap(UserDefaults.init(suiteName:)) ?? .standard)
    #else
    static let shared = EditorSettings()
    #endif
    @ObservationIgnored private let defaults: UserDefaults
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: "editor.fontSize") } }
    var theme: EditorTheme { didSet { defaults.set(theme.rawValue, forKey: "editor.theme") } }
    var tabWidth: Int { didSet { defaults.set(tabWidth, forKey: "editor.tabWidth") } }
    var usesTabs: Bool { didSet { defaults.set(usesTabs, forKey: "editor.usesTabs") } }
    var wrapsLines: Bool { didSet { defaults.set(wrapsLines, forKey: "editor.softWrap") } }
    var showsIndentGuides: Bool { didSet { defaults.set(showsIndentGuides, forKey: "editor.indentGuides") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let size = defaults.object(forKey: "editor.fontSize") as? Double ?? 13.5
        fontSize = size.isFinite ? min(24, max(10, size)) : 13.5
        theme = EditorTheme(rawValue: defaults.string(forKey: "editor.theme") ?? "") ?? .system
        let width = defaults.object(forKey: "editor.tabWidth") as? Int ?? 4
        tabWidth = [2, 4, 8].contains(width) ? width : 4
        usesTabs = defaults.bool(forKey: "editor.usesTabs")
        wrapsLines = defaults.bool(forKey: "editor.softWrap")
        showsIndentGuides = defaults.object(forKey: "editor.indentGuides") as? Bool ?? true
    }
    var style: EditorStyle {
        EditorStyle(fontSize: fontSize, theme: theme, tabWidth: tabWidth, usesTabs: usesTabs,
                    wrapsLines: wrapsLines, showsIndentGuides: showsIndentGuides)
    }
    func reset() {
        fontSize = 13.5; theme = .system; tabWidth = 4
        usesTabs = false; wrapsLines = false; showsIndentGuides = true
    }
    func indentSnippet(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            let prefix = line.prefix { $0 == " " || $0 == "\t" }
            let columns = prefix.reduce(0) { $1 == "\t" ? $0 + 4 - $0 % 4 : $0 + 1 }
            return String(repeating: style.indent, count: columns / 4) + String(line.dropFirst(prefix.count))
        }.joined(separator: "\n")
    }
}

struct EditorSettingsView: View {
    @Bindable var settings: EditorSettings = .shared
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if compact {
                HStack {
                    Label("Editor appearance", systemImage: "textformat.size").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Reset") { settings.reset() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 14) {
                HStack {
                    Text("Theme")
                    Spacer()
                    Picker("Theme", selection: $settings.theme) {
                        ForEach(EditorTheme.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 142)
                }
                HStack {
                    Text("Font size")
                    Spacer()
                    Stepper(value: $settings.fontSize, in: 10...24, step: 0.5) {
                        Text(settings.fontSize.formatted(.number.precision(.fractionLength(0...1))) + " pt")
                            .monospacedDigit().frame(width: 55, alignment: .trailing)
                    }.fixedSize()
                }
            }
            Divider()
            VStack(spacing: 14) {
                HStack {
                    Text("Indent using")
                    Spacer()
                    Picker("Indent using", selection: $settings.usesTabs) {
                        Text("Spaces").tag(false)
                        Text("Tabs").tag(true)
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 142)
                }
                HStack {
                    Text("Tab width")
                    Spacer()
                    Picker("Tab width", selection: $settings.tabWidth) {
                        ForEach([2, 4, 8], id: \.self) { Text("\($0)").tag($0) }
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 142)
                }
                HStack {
                    Text("Indentation guides")
                    Spacer()
                    Toggle("Indentation guides", isOn: $settings.showsIndentGuides).labelsHidden()
                }
                HStack {
                    Text("Wrap long lines")
                    Spacer()
                    Toggle("Wrap long lines", isOn: $settings.wrapsLines).labelsHidden()
                }
            }
            .toggleStyle(.switch).controlSize(.small)
            Text("Changes apply to every open editor. Indentation settings apply as you type and format.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !compact { Button("Restore defaults") { settings.reset() } }
        }
        .font(.system(size: 12)).controlSize(.small)
        .padding(compact ? 18 : 24).frame(width: compact ? 310 : 480)
        .background(Theme.panel)
        .foregroundStyle(.primary)
        #if DEBUG
        .background(DebugViewMarker(name: "editor-settings-panel"))
        #endif
    }
}
