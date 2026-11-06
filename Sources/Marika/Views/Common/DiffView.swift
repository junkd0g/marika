import MarikaCore
import SwiftUI

/// Lines added and removed, e.g. `+12 −3`.
struct DiffStat: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 5) {
            if additions > 0 { Text("+\(additions)").foregroundStyle(Theme.addition) }
            if deletions > 0 { Text("−\(deletions)").foregroundStyle(Theme.deletion) }
        }
        .font(Theme.codeSmall)
        .monospacedDigit()
    }
}

struct DiffView: View {
    let file: DiffFile
    var showsHeader = true
    var initialLimit = 300

    @State private var showsAll = false

    private var visibleLines: ArraySlice<DiffLine> {
        showsAll ? file.lines[...] : file.lines.prefix(initialLimit)
    }

    /// Previews of unapplied edits have no line numbers, so there is no gutter to reserve.
    private var hasLineNumbers: Bool {
        file.lines.contains { $0.oldNumber != nil || $0.newNumber != nil }
    }

    private var gutterDigits: Int {
        let highest = file.lines.reduce(0) { max($0, $1.oldNumber ?? 0, $1.newNumber ?? 0) }
        return max(2, String(highest).count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                HStack {
                    Text(file.movedTo.map { "\(file.path) → \($0)" } ?? file.path)
                        .font(Theme.codeSmall)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    DiffStat(additions: file.additions, deletions: file.deletions)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider()
            }
            if file.isBinary {
                Text("Binary file")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else if file.lines.isEmpty {
                Text("No textual changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visibleLines.enumerated()), id: \.offset) { _, line in
                        DiffLineRow(line: line, gutterDigits: hasLineNumbers ? gutterDigits : 0)
                    }
                }
                if !showsAll, file.lines.count > initialLimit {
                    Button("Show \(file.lines.count - initialLimit) more lines") { showsAll = true }
                        .buttonStyle(.link)
                        .font(.caption)
                        .padding(8)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline)
        }
    }
}

private struct DiffLineRow: View {
    let line: DiffLine
    let gutterDigits: Int

    private var marker: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        default: " "
        }
    }

    private var tint: Color {
        switch line.kind {
        case .addition: Theme.addition.opacity(0.13)
        case .deletion: Theme.deletion.opacity(0.13)
        default: .clear
        }
    }

    var body: some View {
        if line.kind == .hunk {
            Text(line.text)
                .font(Theme.codeSmall)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .background(Theme.surface)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if gutterDigits > 0 {
                    Text(number)
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 8)
                }
                Text(marker)
                    .foregroundStyle(line.kind == .context ? AnyShapeStyle(.tertiary) : AnyShapeStyle(markerColor))
                    .padding(.trailing, 6)
                Text(line.text.isEmpty ? " " : line.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(Theme.codeSmall)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(tint)
        }
    }

    private var markerColor: Color { line.kind == .addition ? Theme.addition : Theme.deletion }

    private var number: String {
        let value = line.newNumber ?? line.oldNumber
        let text = value.map(String.init) ?? ""
        return String(repeating: " ", count: max(0, gutterDigits - text.count)) + text
    }
}
