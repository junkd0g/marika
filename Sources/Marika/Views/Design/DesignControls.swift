import MarikaCore
import SwiftUI

/// A titled group in the inspector, closed by a hairline.
struct DesignSection<Accessory: View, Content: View>: View {
    var title: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack(spacing: 2) {
                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink)
                    Spacer(minLength: 4)
                    accessory()
                }
                .frame(minHeight: 22)
            }
            content()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

extension DesignSection where Accessory == EmptyView {
    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, accessory: { EmptyView() }, content: content)
    }
}

struct DesignIconButton: View {
    let symbol: String
    let help: String
    var active = false
    var size: CGFloat = 26
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size > 28 ? 14 : 12, weight: .medium))
                .foregroundStyle(active ? Color.white : Theme.ink)
                .frame(width: size, height: size)
                .background(active ? Theme.action : hovered && isEnabled ? Color.primary.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: size > 28 ? 8 : 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).opacity(isEnabled ? 1 : 0.35)
        .onHover { hovered = $0 }
        .help(help).accessibilityLabel(help)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

private struct DesignFieldSurface: ViewModifier {
    var focused = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 7).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(focused ? Theme.action : .clear, lineWidth: 1.5) }
    }
}

/// A compact number box. Typing applies as you go, and dragging its label scrubs the value.
struct DesignNumberField: View {
    var label = ""
    var symbol: String?
    /// Nil when the selected layers disagree.
    let value: Double?
    var range: ClosedRange<Double> = -100_000...100_000
    var mixed = "Mixed"
    let help: String
    let onChange: (Double) -> Void
    @State private var text = ""
    @State private var scrubStart: Double?
    @FocusState private var focused: Bool

    private var formatted: String {
        guard let value else { return "" }
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
    private func clamp(_ value: Double) -> Double { min(range.upperBound, max(range.lowerBound, value)) }

    var body: some View {
        HStack(spacing: 5) {
            Group { if let symbol { Image(systemName: symbol) } else { Text(label) } }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 15, height: 28).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2).onChanged { drag in
                    let start = scrubStart ?? value ?? 0
                    scrubStart = start
                    onChange(clamp((start + drag.translation.width).rounded()))
                }.onEnded { _ in scrubStart = nil })
            TextField(value == nil ? mixed : "", text: $text)
                .textFieldStyle(.plain).font(.system(size: 12).monospacedDigit()).focused($focused)
                .accessibilityLabel(help)
        }
        .modifier(DesignFieldSurface(focused: focused))
        .help(help)
        .onAppear { text = formatted }
        .onChange(of: value) { _, _ in if !focused { text = formatted } }
        .onChange(of: focused) { _, now in if !now { text = formatted } }
        .onChange(of: text) { _, next in
            // Only typing applies; text set from the model while unfocused must not echo back.
            guard focused, let parsed = Double(next.replacingOccurrences(of: ",", with: ".")), parsed.isFinite,
                  clamp(parsed) != value else { return }
            onChange(clamp(parsed))
        }
    }
}

/// Six hex digits for the color; opacity has its own box beside it.
struct DesignHexField: View {
    let color: DesignColor?
    let help: String
    let onChange: (DesignColor) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var formatted: String {
        color.map { String(DesignColor($0.red, $0.green, $0.blue).hex.dropFirst()) } ?? ""
    }

    var body: some View {
        TextField(color == nil ? "Mixed" : "", text: $text)
            .textFieldStyle(.plain).font(.system(size: 12).monospaced()).focused($focused)
            .accessibilityLabel(help)
            .modifier(DesignFieldSurface(focused: focused))
            .help(help)
            .onAppear { text = formatted }
            .onChange(of: color) { _, _ in if !focused { text = formatted } }
            .onChange(of: focused) { _, now in if !now { text = formatted } }
            .onChange(of: text) { _, next in
                let digits = next.trimmingCharacters(in: .whitespaces).drop { $0 == "#" }
                guard focused, digits.count == 6, var parsed = DesignColor(hex: String(digits)) else { return }
                parsed.alpha = color?.alpha ?? 1
                if parsed != color { onChange(parsed) }
            }
    }
}

struct DesignColorRow: View {
    let color: DesignColor?
    let help: String
    let onChange: (DesignColor) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ColorPicker(help, selection: Binding(get: { (color ?? .gray).color }, set: { onChange(DesignColor($0)) }))
                .labelsHidden()
            DesignHexField(color: color, help: "\(help) hex", onChange: onChange)
            DesignNumberField(label: "%", value: color.map { $0.alpha * 100 }, range: 0...100, mixed: "–", help: "\(help) opacity") { alpha in
                var next = color ?? .gray
                next.alpha = alpha / 100
                onChange(next)
            }
            .frame(width: 62)
        }
    }
}

struct DesignMenuField<Value: Hashable>: View {
    /// Nil when the selected layers disagree.
    let value: Value?
    let options: [Value]
    let title: (Value) -> String
    let help: String
    let onChange: (Value) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button { onChange(option) } label: {
                    if option == value { Label(title(option), systemImage: "checkmark") } else { Text(title(option)) }
                }
            }
        } label: {
            Text(value.map(title) ?? "Mixed").font(.system(size: 12)).foregroundStyle(Theme.ink).lineLimit(1)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .modifier(DesignFieldSurface())
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.trailing, 8).allowsHitTesting(false)
        }
        .help(help).accessibilityLabel(help).accessibilityValue(value.map(title) ?? "Mixed")
    }
}

/// The zoom level, with the usual ways to change it.
struct DesignZoomMenu: View {
    let canvas: DesignCanvasModel

    var body: some View {
        Menu {
            Button("Zoom In") { canvas.setZoom(canvas.zoom * 1.25) }
            Button("Zoom Out") { canvas.setZoom(canvas.zoom / 1.25) }
            Divider()
            Button("Zoom to Fit (⇧1)") { canvas.fit() }.disabled(canvas.doc.visibleBounds == nil)
            Button("Zoom to Selection (⇧2)") { canvas.fitSelection() }.disabled(canvas.selection.isEmpty)
            Divider()
            ForEach([0.5, 1, 2], id: \.self) { level in
                Button("\(Int(level * 100))%") { canvas.setZoom(level) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(canvas.zoomLabel).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Theme.ink)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Zoom").accessibilityLabel("Zoom").accessibilityValue(canvas.zoomLabel)
    }
}

struct DesignExportMenu: View {
    let canvas: DesignCanvasModel
    var compact = false

    var body: some View {
        Menu {
            Button("Export PNG…") { canvas.export() }
            Button("Export SVG…") { canvas.exportSVG() }
            Button("Copy as PNG") { canvas.copyImage() }
        } label: {
            Label {
                if !compact { Text(canvas.selection.isEmpty ? "Export" : "Export selection") }
            } icon: { Image(systemName: "square.and.arrow.up") }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink)
                .padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(canvas.doc.visibleBounds == nil)
        .accessibilityLabel(canvas.selection.isEmpty ? "Export" : "Export selection")
        .help("Export the selection, or the visible canvas when nothing is selected")
    }
}
