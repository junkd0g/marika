import AppKit
import SwiftUI

struct WorkspaceStatusBadge: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label {
            Text(title).font(.system(size: 11, weight: .medium))
        } icon: {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(tint.opacity(0.10), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct WorkspaceRunRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint).frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(Theme.ink).lineLimit(1)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.action) }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(selected ? Theme.action.opacity(0.11) : hovered ? Theme.surface : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(title + " · " + subtitle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct WorkspaceRunOutput: View {
    let output: String
    var emptyMessage = "No output"
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Output", systemImage: "terminal").font(.system(size: 12, weight: .medium))
                Spacer()
                Button(copied ? "Copied" : "Copy output", systemImage: copied ? "checkmark" : "square.on.square") {
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(output, forType: .string) { copied = true }
                }
                .buttonStyle(WorkspaceButtonStyle(kind: .quiet, compact: true))
                .disabled(output.isEmpty)
            }
            .foregroundStyle(Theme.ink)
            .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 4)
            .background(Theme.surface)
            Divider()
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    Text(output.isEmpty ? emptyMessage : output)
                        .font(Theme.code).lineSpacing(3)
                        .foregroundStyle(output.isEmpty ? Color.secondary : Theme.ink)
                        .fixedSize(horizontal: true, vertical: true)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                }
            }
        }
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline) }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copied = false
        }
        .onChange(of: output) { _, _ in copied = false }
    }
}
