import AppKit
import MarikaCore
import SwiftUI

struct AgentInlineReviewView: View {
    @Bindable var review: AgentReviewWorkspace
    var isVisible = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review agent changes").font(.system(size: 13, weight: .semibold))
                    Text(review.session?.title ?? "Agent worktree").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if review.accepted > 0 { Label("\(review.accepted) accepted", systemImage: "checkmark").foregroundStyle(.green) }
                if review.rejected > 0 { Text("\(review.rejected) rejected").foregroundStyle(.secondary) }
                Button { Task { await review.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(!review.canDecide).help("Refresh proposed changes")
                Button { review.close() } label: { Image(systemName: "xmark") }.help("Return to editor")
            }
            .font(.system(size: 10.5)).buttonStyle(.plain).padding(.horizontal, 14).frame(height: 49).background(Theme.chrome.opacity(0.6))
            Divider()
            if review.agentIsBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("The agent is updating its work. Review will refresh when it finishes.")
                    Spacer()
                    Button("Open chat") { review.openChat() }
                }.font(.system(size: 11)).padding(11).background(Color.accentColor.opacity(0.06))
            }
            if let error = review.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.attention)
                    Text(error).textSelection(.enabled)
                    Spacer()
                    Button { review.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.font(.system(size: 12)).padding(12).background(Theme.attention.opacity(0.08))
            }
            HStack(spacing: 0) {
                fileList
                Divider()
                VStack(spacing: 0) {
                    fileToolbar
                    Divider()
                    reviewContent
                    if review.showsTestOutput { Divider(); testOutput }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 10) {
                Text(review.notice ?? "\(review.hunks.count) changes remaining · Agent worktree")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Button("Feedback", systemImage: "bubble.left") { review.beginFeedback() }.disabled(review.agentIsBusy)
                Button("Accept remaining") { Task { await review.acceptRemaining() } }
                    .buttonStyle(.borderedProminent).disabled(!review.canDecide || review.hunks.isEmpty)
            }.controlSize(.small).font(.system(size: 11)).padding(.horizontal, 12).padding(.vertical, 9)
        }
        .background(Theme.canvas)
        .sheet(isPresented: $review.showsFeedback) { ReviewFeedbackView(review: review) }
        .task(id: review.agentIsBusy) { if !review.agentIsBusy { await review.refresh() } }
        .task(id: isVisible) { if isVisible { await review.monitorTestFreshness() } }
        #if DEBUG
        .background(DebugViewMarker(name: "agent-inline-review"))
        #endif
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Changed files").fontWeight(.medium); Spacer(); Text("\(review.review?.files.count ?? 0)").foregroundStyle(.secondary) }
                .font(.system(size: 11)).padding(12)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(review.review?.files ?? []) { file in
                        Button { review.selectFile(file.path) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: FileVisuals.symbol(file.path)).foregroundStyle(.secondary).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text((file.path as NSString).lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                    let parent = (file.path as NSString).deletingLastPathComponent
                                    if !parent.isEmpty { Text(parent).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                                    DiffStat(additions: file.additions, deletions: file.deletions)
                                }
                                Spacer(minLength: 0)
                            }.padding(9).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                .background(review.selectedPath == file.path ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 6)
            }
            Spacer(minLength: 0)
        }.frame(width: 200).background(Theme.chrome.opacity(0.4))
    }

    private var fileToolbar: some View {
        HStack(spacing: 9) {
            Text(review.selectedPath ?? "Review complete").font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Button { review.move(-1) } label: { Image(systemName: "chevron.up") }.help("Previous change")
            Button { review.move(1) } label: { Image(systemName: "chevron.down") }.help("Next change")
            Text("\(review.hunks.firstIndex(where: { $0.id == review.selectedHunkID }).map { $0 + 1 } ?? 0)/\(review.hunks.count)")
                .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
            Divider().frame(height: 14)
            Button { review.runTests() } label: {
                Label(review.testsRunning ? "Running tests…" : review.testResult != nil ? "Run Again" : "Run tests", systemImage: review.testsRunning ? "hourglass" : "play.circle")
            }.disabled(!review.canDecide).help("Run tests for the proposed code in the agent worktree")
            #if DEBUG
            .background(DebugViewMarker(name: "agent-review-tests"))
            #endif
        }.font(.system(size: 11)).buttonStyle(.plain).padding(.horizontal, 12).frame(height: 36)
    }

    @ViewBuilder private var reviewContent: some View {
        if review.review == nil && review.busy {
            ProgressView("Loading changes…").font(.system(size: 12)).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if review.hunks.isEmpty {
            ContentUnavailableView {
                Label(review.accepted + review.rejected > 0 ? "All changes reviewed" : "No proposed changes", systemImage: "checkmark.circle")
            } description: {
                Text(review.accepted + review.rejected > 0 ? "\(review.accepted) accepted · \(review.rejected) rejected" : "The agent worktree matches its reviewed baseline.")
            } actions: {
                Button("Return to editor") { review.close() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(Array(review.fileHunks.enumerated()), id: \.element.id) { index, hunk in
                            if index > 0 { Text("··· unchanged code ···").font(.system(size: 10)).foregroundStyle(.tertiary) }
                            AgentHunkCard(review: review, hunk: hunk).id(hunk.id)
                        }
                    }.padding(14)
                }
                .onChange(of: review.selectedHunkID) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .top) } }
                }
            }
        }
    }

    private var testOutput: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: review.testsRunning ? "hourglass" : review.testIsCurrent && review.testResult?.succeeded == true ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(review.testIsCurrent && review.testResult?.succeeded == true ? Color.green : .secondary)
                Text(review.testsRunning ? "Running tests" : review.testOutdated ? "Outdated" : !review.testIsCurrent && review.testResult != nil ? "Freshness unverified" : review.testResult?.succeeded == true ? "Tests passed" : "Test results").fontWeight(.medium)
                Text("Agent worktree · \(review.testScope?.title ?? "")").foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if review.testsRunning { Button("Stop") { review.stopTests() } }
                Button { review.showsTestOutput = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }.font(.system(size: 11)).padding(10).background(Theme.chrome.opacity(0.5))
            ScrollView {
                Text(review.testError ?? review.testFreshnessIssue ?? (review.testOutdated ? "Code changed since this run. Run tests again.\n\n" + (review.testResult?.output ?? "") : review.testResult?.output ?? "Waiting for test output…"))
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
        }.frame(height: 175)
    }
}

private struct AgentHunkCard: View {
    @Bindable var review: AgentReviewWorkspace
    let hunk: AgentReviewHunk
    @State private var showsAll = false
    private var lines: [DiffLine] { showsAll ? hunk.display.lines : Array(hunk.display.lines.prefix(250)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(hunk.wholeFile ? "Whole file" : "Line \(hunk.newStart)").foregroundStyle(.secondary)
                DiffStat(additions: hunk.additions, deletions: hunk.deletions)
                Spacer(minLength: 4)
                Button { review.beginFeedback(hunk) } label: { Image(systemName: "bubble.left") }.help("Send feedback about this change")
                    .disabled(review.agentIsBusy)
                Button { review.runTests(hunk: hunk) } label: { Image(systemName: "play.circle") }.help("Test this file's package in the agent worktree")
                    .disabled(!review.canDecide)
                Button("Reject", systemImage: "xmark") { Task { await review.decide(.reject, hunk: hunk) } }
                    .disabled(!review.canDecide)
                    #if DEBUG
                    .background(DebugViewMarker(name: "agent-review-reject-" + hunk.id))
                    #endif
                Button("Accept", systemImage: "checkmark") { Task { await review.decide(.accept, hunk: hunk) } }
                    .tint(.green).disabled(!review.canDecide)
                    #if DEBUG
                    .background(DebugViewMarker(name: "agent-review-accept-" + hunk.id))
                    #endif
            }.font(.system(size: 11)).controlSize(.small).padding(9).background(Theme.chrome.opacity(0.45))
            Divider()
            if hunk.display.isBinary {
                Label("Binary change · accept or reject the whole file", systemImage: "doc.richtext")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(20)
            } else if lines.isEmpty {
                Text("File metadata changed").font(.system(size: 12)).foregroundStyle(.secondary).padding(20)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in AgentReviewLine(line: line, path: hunk.path) }
                }.padding(.vertical, 4)
                if !showsAll, hunk.display.lines.count > 250 {
                    Button("Show \(hunk.display.lines.count - 250) more lines") { showsAll = true }.buttonStyle(.link).font(.system(size: 11)).padding(10)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
    }
}

private struct AgentReviewLine: View {
    let line: DiffLine
    let path: String
    private var tint: Color { line.kind == .addition ? .green.opacity(0.09) : line.kind == .deletion ? .red.opacity(0.09) : .clear }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "").frame(width: 34, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "").frame(width: 34, alignment: .trailing).padding(.trailing, 9)
            Text(line.kind == .addition ? "+" : line.kind == .deletion ? "−" : " ")
                .foregroundStyle(line.kind == .addition ? .green : line.kind == .deletion ? .red : .secondary).frame(width: 16)
            Text(highlighted).textSelection(.enabled).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 10)
        }.font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).padding(.vertical, 2).background(tint)
    }
    private var highlighted: AttributedString {
        let text = line.text.isEmpty ? " " : line.text
        let value = NSMutableAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: CodePalette.foreground])
        for token in CodeSyntax.tokens(in: text, path: path) {
            value.addAttribute(.foregroundColor, value: CodePalette.token(token.kind), range: token.range)
        }
        return AttributedString(value)
    }
}

private struct ReviewFeedbackView: View {
    @Bindable var review: AgentReviewWorkspace
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Feedback for \(review.session?.agent.shortName ?? "the agent")").font(.system(size: 17, weight: .semibold))
            if let hunk = review.feedbackHunk { Text("\(hunk.path) · line \(hunk.newStart)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
            Text("The agent will receive your feedback with the selected change and continue in its worktree.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextEditor(text: $review.feedback).font(.system(size: 13)).frame(height: 150).padding(7)
                .scrollContentBackground(.hidden).background(Theme.canvas, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.hairline))
            HStack {
                Button("Cancel") { review.showsFeedback = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Send to agent") { Task { await review.sendFeedback() } }.buttonStyle(.borderedProminent)
                    .disabled(review.feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || review.busy || review.agentIsBusy)
            }.controlSize(.small)
        }.padding(22).frame(width: 480).background(Theme.panel)
    }
}
