import SwiftUI

struct WorkspaceHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 22, weight: .semibold)).tracking(-0.4)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

/// Shared controls for content toolbars and editing sheets.
struct WorkspaceButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, destructive }
    var kind: Kind = .secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        Appearance(configuration: configuration, kind: kind, compact: compact)
    }

    private struct Appearance: View {
        let configuration: Configuration
        let kind: Kind
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 11.5 : 12.5, weight: .medium))
                .foregroundStyle(kind == .primary ? Theme.canvas : kind == .destructive ? Color.red : Theme.ink)
                .padding(.horizontal, compact ? 10 : 14)
                .frame(height: compact ? 30 : 36)
                .background(fill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(kind == .secondary ? Theme.hairline : .clear)
                }
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: 11))
                .onHover { hovered = $0 }
        }

        private var fill: Color {
            if kind == .primary { return Theme.ink.opacity(configuration.isPressed ? 0.76 : hovered ? 0.88 : 1) }
            if configuration.isPressed { return Color.primary.opacity(0.12) }
            if hovered && isEnabled { return Color.primary.opacity(0.08) }
            return kind == .secondary ? Theme.surface : .clear
        }
    }
}

struct WorkspaceControlSurface: ViewModifier {
    var focused = false
    var height: CGFloat = 38
    var font: Font? = .system(size: 12)
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .font(font)
            .padding(.horizontal, 12)
            .frame(minHeight: height)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(focused ? Theme.action : Theme.hairline.opacity(hovered ? 1 : 0.75), lineWidth: focused ? 1.5 : 1)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovered = $0 }
    }
}

extension View {
    func workspaceControl(focused: Bool = false, height: CGFloat = 38) -> some View {
        modifier(WorkspaceControlSurface(focused: focused, height: height))
    }
}

struct WorkspaceFormField<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content()
        }
    }
}

struct WorkspaceSearchField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.plain).focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }.workspaceControl(focused: focused, height: 36)
    }
}

struct WorkspaceSelect<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    var symbol: String?
    var tint: Color = .secondary
    var height: CGFloat = 38

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, value in
                Button { selection = value } label: {
                    if selection == value { Label(label(value), systemImage: "checkmark") }
                    else { Text(label(value)) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).foregroundStyle(tint).frame(width: 14) }
                Text(label(selection)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 8)
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(maxWidth: .infinity, minHeight: height)
        .workspaceControl(height: height)
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.trailing, 12).allowsHitTesting(false)
        }
        .accessibilityLabel(title).accessibilityValue(label(selection))
    }
}

struct WorkspaceSegmentedControl: View {
    @Binding var selection: Bool
    var firstTitle: String
    var firstSymbol: String
    var secondTitle: String
    var secondSymbol: String
    var iconsOnly = false

    var body: some View {
        HStack(spacing: 3) {
            segment(firstTitle, symbol: firstSymbol, value: false)
            segment(secondTitle, symbol: secondSymbol, value: true)
        }
        .padding(3)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline) }
        .fixedSize()
    }

    private func segment(_ title: String, symbol: String, value: Bool) -> some View {
        Button { selection = value } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                if !iconsOnly { Text(title) }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(selection == value ? Theme.ink : .secondary)
            .padding(.horizontal, iconsOnly ? 11 : 10).frame(height: 28)
            .background(selection == value ? Theme.field : .clear, in: RoundedRectangle(cornerRadius: 7))
            .shadow(color: .black.opacity(selection == value ? 0.06 : 0), radius: 2, y: 1)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
            .accessibilityAddTraits(selection == value ? [.isSelected] : [])
    }
}

/// A flat, rounded text field with hover and focus states, replacing the AppKit bezel.
struct WorkspaceTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<_Label>) -> some View { Field(configuration: configuration) }

    private struct Field: View {
        nonisolated(unsafe) let configuration: TextField<_Label>
        @FocusState private var focused: Bool
        nonisolated init(configuration: TextField<_Label>) { self.configuration = configuration }
        var body: some View {
            configuration.textFieldStyle(.plain).focused($focused)
                .modifier(WorkspaceControlSurface(focused: focused, height: 32, font: nil))
        }
    }
}

extension TextFieldStyle where Self == WorkspaceTextFieldStyle {
    static var workspace: WorkspaceTextFieldStyle { WorkspaceTextFieldStyle() }
}

/// A pill tab bar for switching between sections, replacing the system segmented picker.
struct WorkspaceTabPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    var fillsWidth = true

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { value in
                let selected = selection == value
                Button { selection = value } label: {
                    Text(label(value)).font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.ink : .secondary)
                        .lineLimit(1).padding(.horizontal, 12)
                        .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 26)
                        .background(selected ? Theme.field : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 2, y: 1)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(label(value))
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline) }
        .fixedSize(horizontal: !fillsWidth, vertical: true)
        .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

extension WorkspaceTabPicker where Value == String {
    init(_ title: String, selection: Binding<String>, options: [String], fillsWidth: Bool = true) {
        self.init(title: title, selection: selection, options: options, label: { $0 }, fillsWidth: fillsWidth)
    }
}
