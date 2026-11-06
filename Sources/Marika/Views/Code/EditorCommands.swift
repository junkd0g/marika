import SwiftUI

enum EditorSnippet: String, CaseIterable {
    case goError = "snippet.goError", goTest = "snippet.goTest", swiftGuard = "snippet.swiftGuard", typescriptFunction = "snippet.typescriptFunction"
    var title: String {
        switch self {
        case .goError: "Go · Handle error"
        case .goTest: "Go · Test function"
        case .swiftGuard: "Swift · Guard statement"
        case .typescriptFunction: "TypeScript · Async function"
        }
    }
    var text: String {
        switch self {
        case .goError: "if err != nil {\n\treturn err\n}\n"
        case .goTest: "func TestExample(t *testing.T) {\n\tt.Fatal(\"implement test\")\n}\n"
        case .swiftGuard: "guard let value else {\n    return\n}\n"
        case .typescriptFunction: "async function example() {\n    \n}\n"
        }
    }
}

struct EditorCommands: View {
    var action: (String) -> Void
    var body: some View {
        Button("Go to Definition", systemImage: "arrow.turn.down.right") { action("Definition") }
        Button("Peek Definition", systemImage: "doc.text.magnifyingglass") { action("Peek Definition") }
        Button("Find References", systemImage: "text.magnifyingglass") { action("References") }
        Button("Document Symbols", systemImage: "list.bullet.indent") { action("Symbols") }
        Menu("Inspect") {
            Button("Type Information") { action("Hover") }
            Button("Function Signature") { action("Signature") }
            Button("Completions") { action("Completions") }
        }
        Divider()
        Button("Rename Symbol…", systemImage: "pencil.line") { action("Rename") }
        Button("Refactor…") { action("Refactor") }
        Button("Format Document", systemImage: "text.alignleft") { action("Format") }
        Button("Organize Imports") { action("Organize imports") }
        Menu("Insert Snippet") {
            ForEach(EditorSnippet.allCases, id: \.self) { snippet in
                Button(snippet.title) { action(snippet.rawValue) }
            }
        }
        Divider()
        Button("Fold Block") { action("Fold") }
        Button("Unfold All") { action("Unfold") }
    }
}

struct RenameSymbolView: View {
    @Bindable var ide: IDEWorkspace
    var dismiss: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Rename symbol", systemImage: "pencil.line").font(.system(size: 13, weight: .semibold))
            TextField("New symbol name", text: $ide.renameText)
                .textFieldStyle(.roundedBorder).focused($focused).onSubmit(rename)
            Text("Review the changes across your project before applying them.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Preview Changes", action: rename)
                    .buttonStyle(.borderedProminent).disabled(ide.renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.controlSize(.small)
        }.padding(18).frame(width: 310).onAppear { focused = true }
    }
    private func rename() {
        guard !ide.renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        dismiss(); ide.perform("Rename")
    }
}
