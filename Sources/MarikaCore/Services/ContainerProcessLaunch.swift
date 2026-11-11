import Foundation

/// One launch path for container log streams and port forwards. Keeps the existing
/// login-shell behavior while centralizing executable lookup, quoting and environment overrides.
public struct ContainerProcessLaunch: Sendable {
    public let shellCommand: String
    public let directory: URL
    public let environment: [String: String]

    public init(command: ContainerCommand, directory: URL, environment: [String: String]) throws {
        guard let executable = ShellEnvironment.locate(command.tool, in: environment) else {
            throw ContainerHubError("\(command.tool) is not installed.")
        }
        shellCommand = "exec " + ([executable.path] + command.arguments).map(WorkspaceRuntime.quote).joined(separator: " ")
        self.directory = directory
        self.environment = environment.merging(command.environment) { _, requested in requested }
    }

    public func start(_ process: ProcessGroup) throws {
        try process.start(command: shellCommand, directory: directory, environment: environment)
    }
}
