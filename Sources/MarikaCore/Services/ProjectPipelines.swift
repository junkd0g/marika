import Foundation
import Observation

public struct PipelineResult: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var jobID: String?
    public var image: String?
    public var title: String
    public var runner: String
    public var status: String
    public var log: String
}

public struct PipelineJob: Identifiable, Decodable, Hashable, Sendable {
    public var workflow: String
    public var job: String
    public var runner: String
    public var event: String
    public var reason: String?
    public var id: String { workflow + "/" + job + "/" + event }
    public var title: String { workflow.isEmpty ? "Test, build and verify" : job }
}

public enum PipelineDiscovery {
    // Parse YAML as data, including quoted keys, lists and job dependencies.
    private static let inspect = #"""
    jobs = []
    Dir.glob('.github/workflows/*').sort.select { |p| p =~ /\.ya?ml\z/i }.each do |path|
      begin
        doc = Psych.safe_load(File.read(path))
        definitions = doc.fetch('jobs')
        events = doc['on'] || doc[true]
        names = events.is_a?(Hash) ? events.keys : Array(events)
        meta = doc.reject { |k,v| k == 'jobs' }
        definitions.each do |key, job|
          checked = {}
          check = lambda do |id|
            next if checked[id]
            checked[id] = true
            j = definitions.fetch(id)
            next 'Requires a GitHub reusable workflow' if j['uses']
            next 'Requires a different runner' unless j['runs-on'].to_s =~ /\Aubuntu-(latest|[0-9]+\.[0-9]+)\z/
            next 'Requires GitHub environment or credentials' if j['environment'] || [meta,j].to_json =~ /id-token|secrets\s*[.\[]|github\.token/i
            next 'Requires GitHub artifact storage' if j.to_json =~ /actions\/(upload|download)-artifact@/i
            Array(j['needs']).map { |dep| check.call(dep) }.compact.first
          end
          reason = check.call(key)
          names.each { |event| jobs << {workflow:path, job:key, runner:job['runs-on'].to_s, event:event.to_s, reason:reason} }
        end
      rescue => e
        jobs << {workflow:path, job:'Workflow', runner:'', event:'', reason:e.message}
      end
    end
    puts JSON.generate(jobs)
    """#
    public static func jobs(at root: URL) async throws -> [PipelineJob] {
        let parsed = try await Command.run(URL(fileURLWithPath: "/usr/bin/ruby"), ["-rpsych", "-rjson", "-e", inspect], workingDirectory: root)
        guard parsed.succeeded else { throw NSError(domain: "Workflow discovery", code: 1, userInfo: [NSLocalizedDescriptionKey: parsed.errorOutput]) }
        var jobs = try JSONDecoder().decode([PipelineJob].self, from: parsed.stdout)
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            jobs.insert(PipelineJob(workflow: "", job: "swift", runner: "macOS", event: "", reason: nil), at: 0)
        }
        return jobs
    }
}

@MainActor @Observable public final class ProjectPipelineRunner {
    public private(set) var active: PipelineResult?
    public var onFinish: ((PipelineResult) -> Void)?
    @ObservationIgnored private var child: ProcessGroup?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var logURL: URL?
    public init() {}

    private func quote(_ word: String) -> String { "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public func run(_ job: PipelineJob, root: URL, environment: [String: String], image: String) {
        guard active == nil, job.reason == nil else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result = PipelineResult(jobID: job.id, image: job.workflow.isEmpty ? nil : image, title: job.workflow.isEmpty ? job.title : job.workflow + " · " + job.job + " · " + job.event, runner: job.workflow.isEmpty ? "Local Mac" : "Docker · " + job.runner, status: "Running", log: "")
        active = result
        logURL = file
        let command: String
        if job.workflow.isEmpty {
            var steps = ["swift test"]
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("scripts/build-app.sh").path),
               FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/Marika/App/MarikaApp.swift").path) {
                steps += ["scripts/build-app.sh release", "codesign --verify --deep --strict build/Marika.app"]
            } else { steps.append("swift build -c release") }
            command = steps.map { "print -r -- " + quote("$ " + $0) + "\n" + $0 }.joined(separator: "\n")
        } else {
            let args = ["act", job.event, "-W", job.workflow, "-j", job.job, "-P", job.runner + "=" + image, "--pull=false", "--container-daemon-socket", "-", "--secret-file", "/dev/null", "--env-file", "/dev/null"]
            command = """
            command -v act >/dev/null || { echo 'Install act with brew install act.'; exit 127; }
            docker info >/dev/null || { echo 'Start Docker and check the active Docker context.'; exit 1; }
            export DOCKER_HOST="${DOCKER_HOST:-$(docker context inspect --format '{{.Endpoints.docker.Host}}')}"
            """ + "\n" + "print -r -- " + quote(args.joined(separator: " ")) + "\n" + args.map(quote).joined(separator: " ")
        }
        let process = ProcessGroup(output: { _ in }, completion: { [weak self] code in
            Task { @MainActor in
                guard self?.active?.id == result.id else { return }
                self?.finish(code == 0 ? "Passed" : "Failed (exit \(code))")
            }
        })
        child = process
        var env = environment
        if env["DEVELOPER_DIR"] == nil && FileManager.default.fileExists(atPath: "/Applications/Xcode.app") {
            env["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
        }
        do {
            try process.start(command: "umask 077; exec >" + quote(file.path) + " 2>&1; set -e\n" + command, directory: root, environment: env)
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    self?.refreshLog()
                    try? await Task.sleep(for: .milliseconds(350))
                }
            }
        } catch { active?.log = error.localizedDescription; finish("Failed to start") }
    }
    private func refreshLog() {
        guard let logURL, let handle = try? FileHandle(forReadingFrom: logURL) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        try? handle.seek(toOffset: size > 64_000 ? size - 64_000 : 0)
        let log = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self).withoutTerminalCodes
        if active?.log != log { active?.log = log }
    }
    private func finish(_ status: String) {
        poll?.cancel(); poll = nil
        refreshLog()
        if let logURL { try? FileManager.default.removeItem(at: logURL) }
        logURL = nil
        guard var result = active else { return }
        result.status = status
        active = nil; child = nil
        onFinish?(result)
    }
    public func stop() { guard active != nil else { return }; child?.stop(); finish("Stopped") }
}
