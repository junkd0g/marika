import Foundation
import MarikaCore

extension QAWorkspace {
    func importPlaywrightReport(_ url: URL) async throws {
        guard !busy, let project, let model else { return }
        guard data.environment.count <= 500, !data.build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              data.build.count <= 500, data.url.count <= 4000 else { throw QAError("Enter a CI build identifier and valid QA environment fields.") }
        busy = true
        defer { busy = false }
        let context = (data.environment, data.build, data.url)
        let cases = data.cases
        let imported = try await Task.detached {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let bytes = try file.read(upToCount: QAPlaywrightImport.maximumReportSize + 1) ?? Data()
            return try QAPlaywrightImport(data: bytes, cases: cases)
        }.value
        guard model.project(id: project.id) != nil, cases == data.cases else {
            throw QAError("The project or case library changed. Import the report again.")
        }
        if let old = data.runs.first(where: { $0.playwrightReportDigest == imported.digest }) {
            selectedRunID = old.id; section = "Runs"; return
        }
        guard data.runs.count < 300 else { throw QAError("Export and remove old runs before importing more than 300 runs.") }
        var run = QARun(name: "Playwright · " + context.1, environment: context.0, build: context.1, url: context.2,
                        mode: .playwright, cases: [])
        if let startedAt = imported.startedAt { run.startedAt = startedAt }
        run.finishedAt = Date()
        run.cases = imported.results
        run.playwrightReportDigest = imported.digest
        run.platform = "See CI browser projects"
        run.freshnessNote = "CI source freshness is unverified. \(imported.ignored) test results did not match an approved case revision."
        let id = run.id
        data.runs.append(run)
        guard await model.save() else {
            data.runs.removeAll { $0.id == id }
            throw QAError("Couldn't save the Playwright run. Retry after resolving the storage error.")
        }
        selectedRunID = id; section = "Runs"
    }

    func traceURL(_ id: UUID) -> URL { evidenceDirectory.appendingPathComponent(id.uuidString + ".zip") }

    func attachPlaywrightTrace(_ source: URL, runID: UUID, caseID: UUID, resultID: UUID) async throws {
        guard !busy, let model else { return }
        busy = true
        defer { busy = false }
        let id = UUID(), target = traceURL(id), folder = evidenceDirectory
        try await Task.detached {
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size >= 4, size <= 150_000_000 else {
                throw QAError("Choose a Playwright trace ZIP up to 150 MB.")
            }
            let file = try FileHandle(forReadingFrom: source)
            defer { try? file.close() }
            guard try file.read(upToCount: 4) == Data([0x50, 0x4b, 0x03, 0x04]) else {
                throw QAError("Choose a Playwright trace ZIP.")
            }
            try file.seek(toOffset: 0)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw QAError("Couldn't create the saved trace file.")
            }
            do {
                let output = try FileHandle(forWritingTo: target)
                defer { try? output.close() }
                var copied = 0
                while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
                    copied += chunk.count
                    guard copied <= 150_000_000 else { throw QAError("Choose a Playwright trace ZIP up to 150 MB.") }
                    try output.write(contentsOf: chunk)
                }
            } catch {
                try? FileManager.default.removeItem(at: target)
                throw error
            }
        }.value
        guard project != nil, let (r, c, i) = playwrightIndex(runID: runID, caseID: caseID, resultID: resultID) else {
            try? FileManager.default.removeItem(at: target)
            throw QAError("The imported result is unavailable.")
        }
        let old = data.runs[r].cases[c].playwright?[i].traceID
        data.runs[r].cases[c].playwright?[i].traceID = id
        guard await model.save() else {
            if let (r, c, i) = playwrightIndex(runID: runID, caseID: caseID, resultID: resultID) {
                data.runs[r].cases[c].playwright?[i].traceID = old
            }
            try? FileManager.default.removeItem(at: target)
            throw QAError("Couldn't save the trace link.")
        }
        if let old { try? FileManager.default.removeItem(at: traceURL(old)) }
    }

    func playwrightIndex(runID: UUID, caseID: UUID, resultID: UUID) -> (Int, Int, Int)? {
        guard let r = data.runs.firstIndex(where: { $0.id == runID }),
              let c = data.runs[r].cases.firstIndex(where: { $0.id == caseID }),
              let i = data.runs[r].cases[c].playwright?.firstIndex(where: { $0.id == resultID }) else { return nil }
        return (r, c, i)
    }
}
