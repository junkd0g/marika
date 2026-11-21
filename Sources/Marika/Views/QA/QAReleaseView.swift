import AppKit
import MarikaCore
import SwiftUI

struct QAReleaseView: View {
    @Bindable var qa: QAWorkspace
    @State private var snapshot: VerificationSnapshot?
    @State private var checking = false

    private enum Result: Equatable {
        case passed, failed, blocked, needsVerification, inProgress, notTested, draft

        var title: String {
            switch self {
            case .passed: "Passed"
            case .failed: "Failed"
            case .blocked: "Blocked"
            case .needsVerification: "Needs verification"
            case .inProgress: "In progress"
            case .notTested: "Not tested"
            case .draft: "Draft"
            }
        }

        var symbol: String {
            switch self {
            case .passed: "checkmark.circle.fill"
            case .failed: "xmark.circle.fill"
            case .blocked: "exclamationmark.circle.fill"
            case .needsVerification: "clock.badge.exclamationmark"
            case .inProgress: "clock"
            case .notTested: "circle.dashed"
            case .draft: "pencil"
            }
        }

        var tint: Color {
            switch self {
            case .passed: Theme.addition
            case .failed: Theme.deletion
            case .blocked, .needsVerification: Theme.attention
            case .inProgress: Theme.action
            case .notTested, .draft: .secondary
            }
        }
    }

    var body: some View {
        let rows = QAReleaseCoverage.rows(qa.data, currentSnapshot: snapshot)
        let finishedRuns = Set(qa.data.runs.filter { $0.finishedAt != nil }.map(\.id))
        let entries = rows.map { row in (row, status(row, finishedRuns: finishedRuns)) }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if entries.isEmpty {
                    ContentUnavailableView("No configured cases", systemImage: "checklist",
                        description: Text("Create a QA case to track release coverage."))
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    summary(entries.map { $0.1 })
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Configured cases")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 16).padding(.vertical, 13)
                        LazyVStack(spacing: 0) {
                            ForEach(entries, id: \.0.id) { row, result in
                                Divider()
                                caseRow(row, result: result)
                            }
                        }
                    }.workspaceCard(padding: 0)
                    Text("Coverage is based on the cases configured for this environment and build.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: 1040, alignment: .leading).padding(24).frame(maxWidth: .infinity)
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center) {
                title
                Spacer(minLength: 12)
                actions
            }
            VStack(alignment: .leading, spacing: 12) {
                title
                actions
            }
        }
    }

    private var title: some View {
        Text("Release coverage").font(Theme.displayTitle).foregroundStyle(Theme.ink)
            .accessibilityAddTraits(.isHeader)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(checking ? "Checking…" : "Check source version", systemImage: "arrow.clockwise") {
                Task { await refresh() }
            }.disabled(checking)
            Button("Export summary…", systemImage: "square.and.arrow.up") { export() }
        }.buttonStyle(WorkspaceButtonStyle(compact: true)).fixedSize()
    }

    private func summary(_ results: [Result]) -> some View {
        let passed = results.filter { $0 == .passed }.count
        let failing = results.filter { $0 == .failed || $0 == .blocked }.count
        let verification = results.filter { $0 == .needsVerification }.count
        let remaining = results.count - passed - failing - verification
        let counts = [passed, failing, verification, remaining]
        let colors = [Theme.addition, Theme.deletion, Theme.attention, Theme.hairline]
        return VStack(alignment: .leading, spacing: 14) {
            Text("\(passed) of \(results.count) cases have current passing results")
                .font(.system(size: 15, weight: .semibold))
            GeometryReader { geometry in
                let visible = counts.filter { $0 > 0 }.count
                let width = max(0, geometry.size.width - CGFloat(visible - 1) * 4)
                HStack(spacing: 4) {
                    ForEach(counts.indices, id: \.self) { index in
                        if counts[index] > 0 {
                            Capsule().fill(colors[index])
                                .frame(width: width * CGFloat(counts[index]) / CGFloat(results.count))
                        }
                    }
                }
            }.frame(height: 6).accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { summaryTiles(counts) }.frame(minWidth: 500)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                    summaryTiles(counts)
                }
            }
        }.workspaceCard(padding: 16)
    }

    @ViewBuilder private func summaryTiles(_ counts: [Int]) -> some View {
        tile("Current passes", count: counts[0], symbol: "checkmark.circle", tint: Theme.addition)
        tile("Failed or blocked", count: counts[1], symbol: "xmark.circle", tint: Theme.deletion)
        tile("Needs verification", count: counts[2], symbol: "clock", tint: Theme.attention)
        tile("Pending", count: counts[3], symbol: "circle.dashed", tint: .secondary)
    }

    private func tile(_ title: String, count: Int, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text(count.formatted()).font(.system(size: 21, weight: .semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
            .background(tint.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
    }

    private func caseRow(_ row: QACoverageRow, result: Result) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                caseTitle(row)
                Spacer(minLength: 8)
                rowActions(row, result: result, aligned: true)
            }.frame(minWidth: 550)
            VStack(alignment: .leading, spacing: 8) {
                caseTitle(row)
                rowActions(row, result: result)
            }
        }.padding(.horizontal, 16).padding(.vertical, 9)
    }

    private func caseTitle(_ row: QACoverageRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                qa.selectedCaseID = row.id
                qa.section = "Cases"
            } label: {
                Text(row.testCase.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.action)
            }.buttonStyle(.plain).help("Open case")
            if !row.testCase.requirement.isEmpty {
                Text(row.testCase.requirement).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowActions(_ row: QACoverageRow, result: Result, aligned: Bool = false) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                WorkspaceStatusBadge(title: result.title, symbol: result.symbol, tint: result.tint)
                    .help(row.detail).accessibilityHint(row.detail)
                if result == .needsVerification {
                    Text("Last run · " + row.result.rawValue).font(.caption2).foregroundStyle(.secondary)
                }
            }.frame(width: aligned ? 140 : nil, alignment: .leading)
            Group {
                if let id = row.runID {
                    Button("View run", systemImage: "arrow.up.right") {
                        qa.selectedRunID = id
                        qa.selectedCaseID = row.id
                        qa.section = "Runs"
                    }.buttonStyle(WorkspaceButtonStyle(kind: .quiet, compact: true))
                        .fixedSize(horizontal: true, vertical: false)
                        #if DEBUG
                        .background(DebugViewMarker(name: "qa-release-run-" + id.uuidString))
                        #endif
                } else if aligned {
                    Color.clear.frame(height: 1).accessibilityHidden(true)
                }
            }.frame(width: aligned ? 96 : nil, alignment: .trailing)
        }.fixedSize()
    }

    private func status(_ row: QACoverageRow, finishedRuns: Set<UUID>) -> Result {
        guard row.testCase.approved else { return .draft }
        guard let id = row.runID else { return .notTested }
        guard finishedRuns.contains(id) else { return .inProgress }
        guard row.current else { return .needsVerification }
        switch row.result {
        case .passed: return .passed
        case .failed: return .failed
        case .blocked: return .blocked
        case .notTested: return .notTested
        }
    }

    private func refresh() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        snapshot = await currentSnapshot()
    }

    private func currentSnapshot() async -> VerificationSnapshot? {
        guard let project = qa.project, project.runtime == nil else { return nil }
        return try? await VerificationSnapshot.capture(at: project.url)
    }

    private func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "QA-release-coverage.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let current = await currentSnapshot()
            snapshot = current
            do { try QAReleaseCoverage.markdown(qa.data, currentSnapshot: current).write(to: url, atomically: true, encoding: .utf8) }
            catch { qa.error = error.localizedDescription }
        }
    }
}
