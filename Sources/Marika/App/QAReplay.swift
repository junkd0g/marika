import Foundation
import MarikaCore

extension QAWorkspace {
    func replay(_ test: QACase, retesting: UUID? = nil) async throws {
        guard test.canReplay else { throw QAError("Approve this case and add at least one checkpoint. Every replay step needs a supported browser action.") }
        guard let model, let project else { return }
        let browser = model.browser(for: project)
        guard !recording, replayTask == nil else { throw QAError("Stop the active recording or replay first.") }
        openBrowser()
        guard let replayPage = browser.selectedPage else { throw QAError("Open a browser tab first.") }
        let runID = try await startRun(cases: [test], mode: .replay, retesting: retesting)
        replayTask = Task { [weak self] in
            guard let self else { return }
            self.busy = true
            defer { self.busy = false; self.replayTask = nil }
            for _ in 0..<20 where replayPage.webView.isHidden {
                try? await Task.sleep(for: .milliseconds(100))
            }
            for (index, step) in test.steps.enumerated() {
                do {
                    try Task.checkCancellation()
                    guard let action = step.automation, let page = browser.selectedPage,
                          page.id == replayPage.id, !page.webView.isHidden else { throw QAError("The replay tab changed or is no longer visible. Open it and start a new run.") }
                    try await self.perform(action, page: page, browser: browser)
                    self.changeResult(runID: runID, caseID: test.id, step: index) {
                        $0.status = .passed; $0.actual = step.automation?.isAssertion == true ? "Checkpoint observed in WebKit." : "Browser action completed."
                    }
                } catch {
                    self.changeResult(runID: runID, caseID: test.id, step: index) {
                        $0.status = error is CancellationError ? .blocked : .failed
                        $0.actual = error is CancellationError ? "Replay stopped by tester." : error.localizedDescription
                    }
                    try? await self.attachImage(runID: runID, caseID: test.id, step: index, expectedPage: replayPage)
                    break
                }
            }
            if test.baseline != nil, !Task.isCancelled,
               self.data.runs.first(where: { $0.id == runID })?.cases.first?.needsVisualCheck == true {
                do { try await self.compareBaseline(runID: runID, caseID: test.id, expectedPage: replayPage) }
                catch {
                    self.changeResult(runID: runID, caseID: test.id, step: max(0, test.steps.count - 1)) {
                        $0.status = .blocked; $0.actual = "Visual check incomplete: " + error.localizedDescription
                    }
                }
            }
            await self.finishRun(runID, replayPage: replayPage)
        }
    }

    private func perform(_ action: QAAction, page: BrowserPage, browser: BrowserWorkspace) async throws {
        func checkPage() throws {
            try Task.checkCancellation()
            guard browser.selectedPage === page, !page.webView.isHidden else { throw QAError("The replay tab changed or is no longer visible.") }
        }
        try checkPage()
        if action.kind == .navigate {
            guard let url = URL(string: action.value) else { throw QAError("Invalid recorded address.") }
            _ = try BrowserAddress.validate(url, projectRoot: browser.root)
            page.load(url)
            try await Task.sleep(for: .milliseconds(150))
            for _ in 0..<100 {
                try checkPage()
                if let error = page.navigationError { throw QAError(error) }
                if !page.isLoading { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw QAError("Navigation did not finish within 10 seconds.")
        }
        guard let url = page.url else { throw QAError("Open the page to replay.") }
        _ = try BrowserAddress.validate(url, projectRoot: browser.root)
        let script = try QABrowserActions.script(action)
        var reason = "Checkpoint was not observed."
        for _ in 0..<50 {
            try checkPage()
            if !page.isLoading {
                let result = try await page.evaluate(script)
                if result["ready"]?.bool == true {
                    try await Task.sleep(for: .milliseconds(180)); try checkPage(); return
                }
                reason = result["reason"]?.string ?? reason
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw QAError(reason + " (5 second timeout)")
    }

    func stopReplay() async {
        guard let task = replayTask else { return }
        task.cancel()
        await task.value
    }
}
