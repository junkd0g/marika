import AppKit
import MarikaCore
import Observation

@MainActor @Observable final class QAWorkspace {
    let projectID: UUID
    var data: QAProject { didSet { model?.updateProject(projectID) { $0.qa = data } } }
    var selectedCaseID: UUID?
    var selectedRunID: UUID?
    var section = "Cases"
    var error: String?
    var busy = false
    var recording = false
    var recordingActions: [QAAction] = []
    var pickingCheckpoint = false
    var runFreshness: [UUID: String] = [:]
    private(set) var comparing: Set<String> = []
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored var replayTask: Task<Void, Never>?
    @ObservationIgnored private var recordingPageID: UUID?
    let evidenceDirectory: URL

    init(project: Project, model: AppModel) {
        self.projectID = project.id; self.data = project.qa ?? QAProject(); self.model = model
        evidenceDirectory = model.store.root.appendingPathComponent("qa/" + project.id.uuidString, isDirectory: true)
        selectedCaseID = data.cases.first(where: { !$0.archived })?.id
        selectedRunID = data.runs.last?.id
    }
    var project: Project? { model?.project(id: projectID) }
    var selectedCase: QACase? { data.cases.first { $0.id == selectedCaseID } }
    var selectedRun: QARun? { data.runs.first { $0.id == selectedRunID } }

    func saveCase(_ value: QACase) throws {
        try value.validate()
        var value = value
        if let index = data.cases.firstIndex(where: { $0.id == value.id }) {
            let old = data.cases[index]
            if old != value { value.revision = old.revision + 1; value.approved = false }
            data.cases[index] = value
        } else {
            guard data.cases.count < 500 else { throw QAError("This project has reached its 500-case limit.") }
            data.cases.append(value)
        }
        selectedCaseID = value.id
    }
    func approveCase(_ id: UUID) throws {
        guard let index = data.cases.firstIndex(where: { $0.id == id }) else { return }
        try data.cases[index].validate(); data.cases[index].approved = true
    }
    func archiveCase(_ id: UUID) { if let i = data.cases.firstIndex(where: { $0.id == id }) { data.cases[i].archived.toggle() } }

    func startRun(cases: [QACase], mode: QARun.Mode = .manual, retesting: UUID? = nil) async throws -> UUID {
        guard !busy, !cases.isEmpty, cases.allSatisfy({ $0.approved }), let project else {
            throw QAError("Approve at least one test case before starting a run.")
        }
        guard data.runs.count < 300 else { throw QAError("Export and remove old runs before starting more than 300 runs.") }
        guard data.environment.count <= 500, data.build.count <= 500, data.url.count <= 4000 else { throw QAError("Keep environment and build labels under 500 characters and the address under 4,000.") }
        busy = true; defer { busy = false }
        var run = QARun(name: cases.count == 1 ? cases[0].title : "Regression suite · \(cases.count) cases",
                        environment: data.environment, build: data.build,
                        url: data.url.isEmpty ? model?.projectRuntimeTools[projectID]?.browser?.selectedPage?.url?.absoluteString ?? "" : data.url,
                        mode: mode, cases: cases)
        run.retestsRunID = retesting
        model?.projectRuntimeTools[projectID]?.browser?.selectedPage?.qaDiagnostics = []
        if project.runtime == nil {
            do { run.snapshot = try await VerificationSnapshot.capture(at: project.url) }
            catch { run.freshnessNote = "Source freshness unverified: " + error.localizedDescription }
        } else { run.freshnessNote = "Source freshness unverified for a remote project." }
        data.runs.append(run); selectedRunID = run.id; section = "Runs"
        return run.id
    }

    func changeResult(runID: UUID, caseID: UUID, step: Int, _ change: (inout QAStepResult) -> Void) {
        guard let r = data.runs.firstIndex(where: { $0.id == runID }), data.runs[r].finishedAt == nil,
              let c = data.runs[r].cases.firstIndex(where: { $0.id == caseID }), data.runs[r].cases[c].steps.indices.contains(step) else { return }
        change(&data.runs[r].cases[c].steps[step])
    }

    func finishRun(_ id: UUID, replayPage: BrowserPage? = nil) async {
        guard let run = data.runs.first(where: { $0.id == id }), run.finishedAt == nil else { return }
        var note = run.freshnessNote
        if let snapshot = run.snapshot, let project {
            do {
                if try await VerificationSnapshot.capture(at: project.url) != snapshot {
                    note = "Source changed during this run. Retest the current build."
                }
            } catch { note = "Source freshness unverified: " + error.localizedDescription }
        }
        guard let index = data.runs.firstIndex(where: { $0.id == id }), data.runs[index].finishedAt == nil else { return }
        data.runs[index].freshnessNote = note
        data.runs[index].diagnostics = (replayPage ?? model?.projectRuntimeTools[projectID]?.browser?.selectedPage)?.qaDiagnostics ?? []
        data.runs[index].finishedAt = Date()
        await checkFreshness(id)
    }

    func checkFreshness(_ id: UUID) async {
        guard let run = data.runs.first(where: { $0.id == id }), let project else { return }
        guard let snapshot = run.snapshot else { runFreshness[id] = run.freshnessNote ?? "Source freshness unverified"; return }
        do {
            let current = try await VerificationSnapshot.capture(at: project.url)
            runFreshness[id] = current == snapshot ? (run.freshnessNote ?? "Source matches this run") : "Outdated — source changed; retest"
        } catch { runFreshness[id] = "Source freshness unverified" }
    }

    func openBrowser() {
        guard let model, let project else { return }
        _ = model.browser(for: project); model.switchPanel(.qa); model.setSplit(.browser)
        let browser = model.browser(for: project)
        if browser.selectedPage?.url == nil, !data.url.isEmpty { browser.navigate(data.url) }
    }

    func startRecording() throws {
        guard let model, let project, !busy else { return }
        let browser = model.browser(for: project)
        guard let page = browser.selectedPage, let url = page.url else { throw QAError("Open the page to test in Browser first.") }
        recording = true; recordingPageID = page.id
        browser.recordingPage = page
        recordingActions = [QAAction(.navigate, value: url.absoluteString)]
        browser.onQAAction = { [weak self, weak browser] pageID, action in
            guard let self, self.recording, pageID == self.recordingPageID, browser?.selectedPageID == pageID else { return }
            guard self.recordingActions.count < 100 else { self.error = "Recording reached 100 actions. Stop and review this journey."; return }
            if [.fill, .manual].contains(action.kind), let last = self.recordingActions.last,
               last.kind == action.kind, last.selector == action.selector { self.recordingActions[self.recordingActions.count - 1] = action }
            else { self.recordingActions.append(action) }
        }
        openBrowser()
    }
    func stopRecording() throws {
        guard recording else { return }
        let steps = recordingActions.map { action in
            QAStep(action: action.description, expected: action.isAssertion ? action.value : "Action completes", automation: action)
        }
        recording = false
        if let browser = model?.projectRuntimeTools[projectID]?.browser {
            browser.recordingPage = nil
            browser.onQAAction = nil
        }
        try saveCase(QACase(title: "Recorded journey", requirement: "Review recorded actions and add observable checkpoints before approval.", steps: steps))
        recordingActions = []; section = "Cases"
    }

    func addCheckpoint() async throws {
        guard let model, let project, selectedCase != nil else { return }
        openBrowser(); pickingCheckpoint = true
        await model.browser(for: project).annotate()
    }
    func acceptCheckpoint(_ selection: JSONValue?) throws {
        guard pickingCheckpoint, let selection, let selector = selection["selector"]?.string,
              var test = selectedCase else { return }
        let value = selection["text"]?.string ?? ""
        let action = QAAction(value.isEmpty ? .assertVisible : .assertText, selector: selector, value: value)
        test.steps.append(QAStep(action: action.description, expected: value.isEmpty ? "Element is visible" : value, automation: action))
        try saveCase(test); pickingCheckpoint = false
        if let project { model?.browser(for: project).clearFeedback() }
    }

    func evidenceURL(_ value: QAEvidence) -> URL? {
        guard value.filename == URL(fileURLWithPath: value.filename).lastPathComponent,
              value.filename.hasSuffix(".png"), UUID(uuidString: String(value.filename.dropLast(4))) != nil else { return nil }
        return evidenceDirectory.appendingPathComponent(value.filename)
    }
    func saveImage(_ input: Data, title: String, url: String? = nil) throws -> QAEvidence {
        let image = try QAImages.normalize(input)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let name = UUID().uuidString + ".png"
        try image.data.write(to: evidenceDirectory.appendingPathComponent(name), options: .atomic)
        return QAEvidence(filename: name, title: title, url: url, width: image.width, height: image.height)
    }

    func captureImage(expectedPage: BrowserPage? = nil) async throws -> QAEvidence {
        guard let browser = model?.projectRuntimeTools[projectID]?.browser, let page = browser.selectedPage,
              expectedPage == nil || page === expectedPage,
              page.webView.window != nil, !page.webView.isHidden else { throw QAError("Open Browser beside QA to capture the visible page.") }
        let address = page.url
        let image = try await page.screenshot()
        guard browser.selectedPage === page, page.url == address, !page.webView.isHidden else {
            throw QAError("The page changed while capturing evidence.")
        }
        var evidence = try saveImage(image, title: "Browser screenshot", url: address?.absoluteString)
        evidence.viewportWidth = Int(page.webView.bounds.width); evidence.viewportHeight = Int(page.webView.bounds.height); evidence.zoom = page.zoom
        return evidence
    }

    func captureBaseline(_ id: UUID) async throws {
        let evidence = try await captureImage()
        guard let index = data.cases.firstIndex(where: { $0.id == id }) else { return }
        data.cases[index].baseline = evidence; data.cases[index].revision += 1; data.cases[index].approved = false
    }

    func attachImage(runID: UUID, caseID: UUID, step: Int, input: Data? = nil, expectedPage: BrowserPage? = nil) async throws {
        try validateAttachment(runID: runID, caseID: caseID, step: step)
        let image: QAEvidence
        if let input { image = try saveImage(input, title: "Tester attachment") } else { image = try await captureImage(expectedPage: expectedPage) }
        do {
            try validateAttachment(runID: runID, caseID: caseID, step: step)
            changeResult(runID: runID, caseID: caseID, step: step) { $0.evidence.append(image) }
        } catch {
            if let url = evidenceURL(image) { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private func validateAttachment(runID: UUID, caseID: UUID, step: Int) throws {
        guard let run = data.runs.first(where: { $0.id == runID }), run.finishedAt == nil,
              let result = run.cases.first(where: { $0.id == caseID }), result.steps.indices.contains(step) else {
            throw QAError("This run is finished or unavailable. Attach evidence to an active run.")
        }
        guard result.steps[step].evidence.count < 12 else { throw QAError("This step already has 12 images.") }
    }

    func isComparing(runID: UUID, caseID: UUID) -> Bool { comparing.contains(runID.uuidString + ":" + caseID.uuidString) }

    func compareBaseline(runID: UUID, caseID: UUID, tolerance: Double = 0.005, expectedPage: BrowserPage? = nil) async throws {
        guard let r = data.runs.firstIndex(where: { $0.id == runID }), data.runs[r].finishedAt == nil,
              let c = data.runs[r].cases.firstIndex(where: { $0.id == caseID }),
              let baseline = data.runs[r].cases[c].testCase.baseline, let path = evidenceURL(baseline) else {
            throw QAError("Capture and approve a baseline before starting this run.")
        }
        let key = runID.uuidString + ":" + caseID.uuidString
        guard comparing.insert(key).inserted else { throw QAError("This comparison is already running.") }
        defer { comparing.remove(key) }
        let previous = data.runs[r].cases[c].visual
        updateVisual(runID: runID, caseID: caseID, visual: nil, error: nil)
        do {
            let current = try await captureImage(expectedPage: expectedPage)
            guard current.viewportWidth == baseline.viewportWidth, current.viewportHeight == baseline.viewportHeight,
                  current.zoom == baseline.zoom, current.url == baseline.url else {
                throw QAError("Use the baseline's page, viewport size and zoom before comparing.")
            }
            guard let actualURL = evidenceURL(current) else { throw QAError("The captured screenshot is unavailable.") }
            let left = try Data(contentsOf: path), right = try Data(contentsOf: actualURL)
            let diff = try await Task.detached(priority: .userInitiated) { try QAImages.compare(baseline: left, actual: right) }.value
            try Task.checkCancellation()
            let evidence = try saveImage(diff.png, title: "Visual difference", url: current.url)
            var visual = QAVisualResult(baseline: baseline, actual: current, difference: evidence,
                                        changedFraction: diff.changedFraction, allowedFraction: tolerance)
            visual.ticketID = previous?.ticketID
            updateVisual(runID: runID, caseID: caseID, visual: visual, error: nil)
        } catch {
            updateVisual(runID: runID, caseID: caseID, visual: previous, error: error.localizedDescription)
            throw error
        }
    }

    private func updateVisual(runID: UUID, caseID: UUID, visual: QAVisualResult?, error: String?) {
        guard let currentRun = data.runs.firstIndex(where: { $0.id == runID }), data.runs[currentRun].finishedAt == nil,
              let currentCase = data.runs[currentRun].cases.firstIndex(where: { $0.id == caseID }) else { return }
        data.runs[currentRun].cases[currentCase].visual = visual
        data.runs[currentRun].cases[currentCase].visualError = error
    }
}
