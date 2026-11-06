import AppKit
import MarikaCore
import Observation
import SwiftUI

@MainActor @Observable final class CodeNavigationPresentation {
    var title = "Definition"
    var locations: [EditorCodeLocation] = []
    var selected = 0
}

struct CodeNavigationPreview: View {
    @Bindable var state: CodeNavigationPresentation
    var select: (Int) -> Void
    var open: (Int) -> Void
    var close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(state.title, systemImage: "arrow.turn.down.right").fontWeight(.medium)
                Text("\(state.locations.count)").foregroundStyle(.secondary)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close preview (Esc)")
            }.font(.system(size: 11)).padding(11)
            Divider()
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(state.locations.enumerated()), id: \.element.id) { index, location in
                                Button { select(index) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("\((location.path as NSString).lastPathComponent):\(location.line)").font(.system(size: 11, weight: .medium)).lineLimit(1)
                                        Text(location.path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                        .background(state.selected == index ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                }.buttonStyle(.plain).id(index)
                            }
                        }.padding(5)
                    }.onChange(of: state.selected) { _, index in proxy.scrollTo(index) }
                }.frame(width: 180)
                Divider()
                if state.locations.indices.contains(state.selected) {
                    let location = state.locations[state.selected]
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Line \(location.line)").foregroundStyle(.secondary)
                            Spacer()
                            Button("Open file") { open(state.selected) }.controlSize(.small)
                                #if DEBUG
                                .background(DebugViewMarker(name: "navigation-open-file"))
                                #endif
                        }.font(.system(size: 10)).padding(10)
                        ScrollView([.vertical, .horizontal]) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(location.preview.components(separatedBy: "\n").enumerated()), id: \.offset) { index, line in
                                    HStack(alignment: .top, spacing: 10) {
                                        Text("\(location.previewLine + index)").foregroundStyle(.tertiary).frame(width: 30, alignment: .trailing)
                                        Text(highlight(line, path: location.path)).textSelection(.enabled)
                                    }.font(.system(size: 11, design: .monospaced)).padding(.vertical, 4).padding(.horizontal, 8)
                                        .frame(minWidth: 350, alignment: .leading)
                                        .background(location.previewLine + index == location.line ? Color.accentColor.opacity(0.1) : .clear)
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            Text("↑↓ choose · Return opens the file · Esc closes preview").font(.system(size: 10)).foregroundStyle(.secondary).padding(8)
        }.background(Theme.panel).foregroundStyle(.primary)
            .clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline))
            #if DEBUG
            .background(DebugViewMarker(name: "code-navigation-preview"))
            #endif
    }
    private func highlight(_ line: String, path: String) -> AttributedString {
        let text = line.isEmpty ? " " : line
        let value = NSMutableAttributedString(string: text, attributes: [.foregroundColor: CodePalette.foreground])
        for token in CodeSyntax.tokens(in: text, path: path) { value.addAttribute(.foregroundColor, value: CodePalette.token(token.kind), range: token.range) }
        return AttributedString(value)
    }
}
