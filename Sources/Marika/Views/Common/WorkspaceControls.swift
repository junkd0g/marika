import SwiftUI

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
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
                .foregroundStyle(kind == .primary ? Color.white : kind == .destructive ? Color.red : Theme.ink)
                .padding(.horizontal, compact ? 10 : 14)
                .frame(height: compact ? 30 : 36)
                .background(fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(kind == .secondary ? Theme.hairline : .clear)
                }
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: 9))
                .onHover { hovered = $0 }
        }

        private var fill: Color {
            if kind == .primary { return Theme.action.opacity(configuration.isPressed ? 0.76 : hovered ? 0.88 : 1) }
            if configuration.isPressed { return Color.primary.opacity(0.12) }
            if hovered && isEnabled { return Color.primary.opacity(0.08) }
            return kind == .secondary ? Theme.surface : .clear
        }
    }
}

struct WorkspaceControlSurface: ViewModifier {
    var focused = false
    var height: CGFloat = 38
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(minHeight: height)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(focused ? Theme.action : Color.primary.opacity(hovered ? 0.22 : 0.12), lineWidth: focused ? 1.5 : 1)
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
