import Foundation

public struct QAError: LocalizedError, Sendable {
    public var errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

public enum QAStatus: String, Codable, CaseIterable, Sendable {
    case notTested = "Not tested", passed = "Passed", failed = "Failed", blocked = "Blocked"
}

public struct QAAction: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case navigate, click, fill, select, check, submit, assertText, assertVisible, manual
    }
    public var kind: Kind
    public var selector: String
    public var value: String
    public init(_ kind: Kind, selector: String = "", value: String = "") {
        self.kind = kind; self.selector = selector; self.value = value
    }
    public var isAssertion: Bool { kind == .assertText || kind == .assertVisible }
    public var description: String {
        switch kind {
        case .navigate: "Open " + value
        case .click: "Click " + selector
        case .fill: "Enter text in " + selector
        case .select: "Select " + value + " in " + selector
        case .check: (value == "true" ? "Check " : "Uncheck ") + selector
        case .submit: "Submit " + selector
        case .assertText: "Check text in " + selector
        case .assertVisible: "Check " + selector + " is visible"
        case .manual: value
        }
    }
}

public struct QAStep: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var action: String
    public var expected: String
    public var automation: QAAction?
    public init(action: String, expected: String, automation: QAAction? = nil) {
        self.action = action; self.expected = expected; self.automation = automation
    }
}

public struct QAEvidence: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var filename: String
    public var title: String
    public var date = Date()
    public var url: String?
    public var width: Int
    public var height: Int
    public var viewportWidth: Int?
    public var viewportHeight: Int?
    public var zoom: Double?
    public init(filename: String, title: String, url: String? = nil, width: Int, height: Int) {
        self.filename = filename; self.title = title; self.url = url; self.width = width; self.height = height
    }
}

public struct QACase: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var revision = 1
    public var title: String
    public var requirement: String
    public var preconditions: String
    public var steps: [QAStep]
    public var approved = false
    public var archived = false
    public var ticketID: UUID?
    public var designIDs: [UUID] = []
    public var baseline: QAEvidence?
    public init(title: String, requirement: String = "", preconditions: String = "", steps: [QAStep] = []) {
        self.title = title; self.requirement = requirement; self.preconditions = preconditions; self.steps = steps
    }
    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 240,
              requirement.count <= 12_000, preconditions.count <= 8_000, !steps.isEmpty, steps.count <= 100,
              steps.allSatisfy({ !$0.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  !$0.expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  $0.action.count <= 4000 && $0.expected.count <= 4000 &&
                  ($0.automation?.selector.count ?? 0) <= 4000 && ($0.automation?.value.count ?? 0) <= 4000 }) else {
            throw QAError("Give the case a title and 1–100 steps with an action and expected result. Keep the requirement under 12,000 characters.")
        }
    }
    public var canReplay: Bool {
        approved && steps.first?.automation?.kind == .navigate && steps.allSatisfy { $0.automation != nil && $0.automation?.kind != .manual }
            && steps.contains { $0.automation?.isAssertion == true }
    }
}

public struct QAStepResult: Codable, Hashable, Sendable {
    public var status: QAStatus = .notTested
    public var actual = ""
    public var evidence: [QAEvidence] = []
    public var ticketID: UUID?
    public init() {}
}

public struct QAVisualResult: Codable, Hashable, Sendable {
    public var ticketID: UUID?
    public var baseline: QAEvidence
    public var actual: QAEvidence
    public var difference: QAEvidence?
    public var changedFraction: Double
    public var allowedFraction: Double
    public var passed: Bool { changedFraction <= allowedFraction }
    public init(baseline: QAEvidence, actual: QAEvidence, difference: QAEvidence?, changedFraction: Double, allowedFraction: Double) {
        self.baseline = baseline; self.actual = actual; self.difference = difference
        self.changedFraction = changedFraction; self.allowedFraction = allowedFraction
    }
}

public struct QACaseResult: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID { testCase.id }
    /// An immutable definition for this run, independent of subsequent case edits.
    public var testCase: QACase
    public var steps: [QAStepResult]
    public var visual: QAVisualResult?
    public var visualError: String?
    public var playwright: [QAPlaywrightResult]?
    public init(_ testCase: QACase) { self.testCase = testCase; steps = testCase.steps.map { _ in QAStepResult() } }
    public var stepsPassed: Bool {
        !steps.isEmpty && steps.count == testCase.steps.count && steps.allSatisfy { $0.status == .passed }
    }
    public var needsVisualCheck: Bool { testCase.baseline != nil && stepsPassed }
    public var status: QAStatus {
        if let playwright {
            if playwright.contains(where: { $0.status == .failed }) { return .failed }
            if playwright.contains(where: { $0.status != .passed }) || testCase.baseline != nil { return .blocked }
            return playwright.isEmpty ? .notTested : .passed
        }
        if steps.contains(where: { $0.status == .failed }) { return .failed }
        if steps.contains(where: { $0.status == .blocked }) || visualError != nil { return .blocked }
        if visual?.passed == false { return .failed }
        if testCase.baseline != nil && visual == nil { return .notTested }
        return stepsPassed ? .passed : .notTested
    }
}

public struct QARun: Codable, Hashable, Identifiable, Sendable {
    public enum Mode: String, Codable, Sendable { case manual = "Manual", replay = "WebKit replay", playwright = "Playwright CI" }
    public var id = UUID()
    public var startedAt = Date()
    public var finishedAt: Date?
    public var name: String
    public var environment: String
    public var build: String
    public var url: String
    public var mode: Mode
    public var snapshot: VerificationSnapshot?
    public var freshnessNote: String?
    public var playwrightReportDigest: String?
    public var cases: [QACaseResult]
    public var retestsRunID: UUID?
    public var platform = ProcessInfo.processInfo.operatingSystemVersionString
    public var diagnostics: [String] = []
    public init(name: String, environment: String, build: String, url: String, mode: Mode, cases: [QACase]) {
        self.name = name; self.environment = environment; self.build = build; self.url = url; self.mode = mode
        self.cases = cases.map(QACaseResult.init)
    }
    public var counts: [QAStatus: Int] { Dictionary(grouping: cases, by: \.status).mapValues(\.count) }
    public var isPassed: Bool { finishedAt != nil && !cases.isEmpty && cases.allSatisfy { $0.status == .passed } }
}

public struct QADraft: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var source: String
    public var ticketID: UUID?
    public var designIDs: [UUID]
    public var cases: [QACase] = []
    public init(id: UUID, sessionID: UUID, source: String, ticketID: UUID? = nil, designIDs: [UUID] = []) {
        self.id = id; self.sessionID = sessionID; self.source = source; self.ticketID = ticketID; self.designIDs = designIDs
    }
}

public struct QAProject: Codable, Hashable, Sendable {
    public var environment = "Local"
    public var build = "Working tree"
    public var url = ""
    public var cases: [QACase] = []
    public var runs: [QARun] = []
    public var drafts: [QADraft] = []
    public init() {}

    /// A browser replay cannot resume after its process disappears. Preserve its observations,
    /// but require a fresh replay instead of leaving an unfinishable or apparently passing run.
    @discardableResult public mutating func recoverInterruptedReplays(at date: Date = Date()) -> Bool {
        var changed = false
        for r in runs.indices where runs[r].mode == .replay && runs[r].finishedAt == nil {
            for c in runs[r].cases.indices {
                guard !runs[r].cases[c].steps.isEmpty else { continue }
                let index = runs[r].cases[c].steps.firstIndex(where: { $0.status == .notTested }) ?? runs[r].cases[c].steps.index(before: runs[r].cases[c].steps.endIndex)
                if runs[r].cases[c].steps[index].status != .failed {
                    runs[r].cases[c].steps[index].status = .blocked
                    runs[r].cases[c].steps[index].actual = "Replay was interrupted when Marika closed. Start a new replay."
                }
            }
            runs[r].finishedAt = date; changed = true
        }
        return changed
    }

    public mutating func publishDraft(_ id: UUID, callerID: UUID, json: String) throws {
        guard let index = drafts.firstIndex(where: { $0.id == id && $0.sessionID == callerID }) else {
            throw QAError("Publish only to the QA draft assigned to this chat.")
        }
        drafts[index].cases = try QATools.cases(from: json, ticketID: drafts[index].ticketID, designIDs: drafts[index].designIDs)
    }
}

public struct QATicketSource: Codable, Hashable, Sendable {
    public var projectID: UUID
    public var runID: UUID
    public var caseID: UUID
    public var stepID: UUID
    public init(projectID: UUID, runID: UUID, caseID: UUID, stepID: UUID) {
        self.projectID = projectID; self.runID = runID; self.caseID = caseID; self.stepID = stepID
    }
}
