#if DEBUG
import AppKit
import JavaScriptCore
import MarikaCore

@MainActor enum DebugQAChecks {
    private static func checkRecorderGate() throws {
        guard let js = JSContext() else { throw QAError("Couldn’t create the recorder test context.") }
        js.evaluateScript("""
            const messages = [], inputs = [];
            const window = {addEventListener(){}, webkit:{messageHandlers:{marikaQA:{postMessage(m){messages.push(m)}}}}};
            class AbortController { signal = {aborted:false}; abort(){this.signal.aborted=true} }
            const document = {querySelectorAll(){return [1]}, addEventListener(name, fn, options){
                if(name === 'input') inputs.push({fn, signal:options.signal});
            }};
            function type(value) {
                const target = {tagName:'INPUT',type:'text',name:'title',value,getAttribute(k){return k==='name'?'title':null}};
                for(const input of inputs) if (!input.signal.aborted) input.fn({target,isTrusted:true});
            }
            """)
        js.evaluateScript(QARecorderScript.source)
        js.evaluateScript("type('before'); window.__marikaSetQARecording(true); type('during'); window.__marikaSetQARecording(false); type('after')")
        guard js.exception == nil, js.evaluateScript("messages.length === 1 && messages[0].value === 'during'")?.toBool() == true else {
            throw QAError("QA recorder forwarded input outside an active recording.")
        }
    }

    static func regressions(_ model: AppModel) async throws {
        guard let project = model.selectedProject, DebugFixtureSettings.value("MARIKA_DATA") != nil else {
            throw QAError("Use an isolated QA fixture.")
        }
        try checkRecorderGate()
        model.setSplit(.terminal)
        guard model.projectRuntimeTools[project.id]?.terminal != nil else { throw QAError("Terminal split did not initialize.") }
        model.setSplit(.containers)
        guard model.projectRuntimeTools[project.id]?.containers != nil else { throw QAError("Container split did not initialize.") }
        let qa = model.qa(for: project), original = qa.data
        let selection = (qa.selectedCaseID, qa.selectedRunID, qa.section)
        defer { qa.data = original; qa.selectedCaseID = selection.0; qa.selectedRunID = selection.1; qa.section = selection.2 }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32),
              let pixels = bitmap.bitmapData else { throw QAError("Could not create fixture evidence.") }
        for i in 0..<16 { pixels[i] = 255 }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw QAError("Could not encode fixture evidence.") }
        var evidence = try qa.saveImage(png, title: "Regression fixture")
        evidence.viewportWidth = -1 // Deliberately incompatible with any real browser viewport.
        var test = QACase(title: "Visual comparison failure", steps: [QAStep(action: "Check", expected: "Shown")])
        test.approved = true; test.baseline = evidence
        let id = try await qa.startRun(cases: [test])
        qa.changeResult(runID: id, caseID: test.id, step: 0) { $0.status = .passed }
        guard let index = qa.data.runs.firstIndex(where: { $0.id == id }) else { throw QAError("Missing fixture run.") }
        qa.data.runs[index].cases[0].visual = QAVisualResult(baseline: evidence, actual: evidence, difference: nil, changedFraction: 0, allowedFraction: 0.005)
        do {
            try await qa.compareBaseline(runID: id, caseID: test.id)
            throw QAError("A comparison accepted an incompatible viewport.")
        } catch {
            guard qa.data.runs[index].cases[0].status == .blocked,
                  qa.data.runs[index].cases[0].visualError != nil else { throw QAError("A failed comparison reused an earlier passing result.") }
        }
        qa.changeResult(runID: id, caseID: test.id, step: 0) { $0.evidence = Array(repeating: evidence, count: 12) }
        do {
            try await qa.attachImage(runID: id, caseID: test.id, step: 0, input: png)
            throw QAError("The evidence limit was silently ignored.")
        } catch {
            guard error.localizedDescription == "This step already has 12 images." else { throw error }
        }
        qa.openBrowser()
        let browser = model.browser(for: project)
        guard let replayPage = browser.selectedPage else { throw QAError("Missing replay page.") }
        replayPage.qaDiagnostics = ["Replay page"]
        let otherPage = browser.newPage()
        otherPage.qaDiagnostics = ["Unrelated page"]
        do {
            _ = try await qa.captureImage(expectedPage: replayPage)
            throw QAError("Captured the wrong tab.")
        } catch {
            guard error.localizedDescription.contains("Browser beside QA") else { throw error }
        }
        await qa.finishRun(id, replayPage: replayPage)
        guard qa.data.runs[index].diagnostics == ["Replay page"] else { throw QAError("Collected diagnostics from the wrong tab.") }
        browser.close(otherPage)
        model.setSplit(nil)
        do {
            try await qa.attachImage(runID: id, caseID: test.id, step: 0, input: png)
            throw QAError("A finished run accepted new evidence.")
        } catch {
            guard error.localizedDescription.contains("run is finished") else { throw error }
        }
    }

    static func restored(_ model: AppModel) throws {
        guard let project = model.selectedProject, let qa = model.projectRuntimeTools[project.id]?.qa, !qa.data.runs.isEmpty else {
            throw QAError("The QA panel was not restored with its saved runs.")
        }
    }
    static func run(_ model: AppModel) async throws {
        guard let project = model.selectedProject, let owner = model.selectedSessionID,
              DebugFixtureSettings.value("MARIKA_DATA") != nil else { throw QAError("Use an isolated QA fixture.") }
        let qa = model.qa(for: project)
        var test = QACase(title: "Expired discount code", requirement: "Expired discounts must not reduce the total.",
            preconditions: "Open checkout. Use discount EXPIRED.", steps: [
                QAStep(action: "Enter EXPIRED in Discount code and choose Apply", expected: "Show Discount expired and keep the total unchanged"),
                QAStep(action: "Remove the code", expected: "Clear the error and preserve cart items")])
        try qa.saveCase(test); try qa.approveCase(test.id)
        test = qa.selectedCase!
        let run = try await qa.startRun(cases: [test])
        qa.changeResult(runID: run, caseID: test.id, step: 0) { $0.status = .failed; $0.actual = "The expired discount was applied to the total." }
        let ticket = try await model.createQABug(project: project, runID: run, caseID: test.id, step: 0)
        guard try await model.createQABug(project: project, runID: run, caseID: test.id, step: 0) == ticket,
              model.ticketLocation(ticket)?.ticket.qaSource?.runID == run else { throw QAError("QA bug creation is not idempotent or lost its source.") }
        await qa.finishRun(run)
        guard qa.selectedRun?.isPassed == false, qa.selectedRun?.cases[0].steps[1].status == .notTested else { throw QAError("Incomplete QA work was reported passed.") }
        var changed = test; changed.steps[0].expected = "Show a clear expiry error; preserve total and items"
        try qa.saveCase(changed)
        guard qa.selectedCase?.approved == false,
              qa.selectedRun?.cases[0].testCase.steps[0].expected == test.steps[0].expected else { throw QAError("Editing a case changed historical results.") }
        let draftID = UUID()
        qa.data.drafts.append(QADraft(id: draftID, sessionID: owner, source: "Draft another discount edge case"))
        _ = try model.publishQACases(["draftID": .string(draftID.uuidString), "draft": #"{"cases":[{"title":"Empty code","requirement":"Ignore an empty discount","preconditions":"Open checkout","steps":[{"action":"Apply a blank discount","expected":"Keep total unchanged"}]}]}"#], project: project, callerID: owner)
        guard qa.data.drafts[0].cases.first?.approved == false else { throw QAError("Generated cases were silently approved.") }
        guard await model.save() else { throw QAError("QA fixture did not save.") }
        let saved = try await model.store.loadWorkspace()
        guard saved.projects.first(where: { $0.id == project.id })?.qa?.runs.first?.cases[0].steps[0].ticketID == ticket else {
            throw QAError("QA evidence links did not persist.")
        }
        qa.section = "Cases"; qa.selectedCaseID = test.id
        model.openProject(project, tab: .qa)
    }
}
#endif
