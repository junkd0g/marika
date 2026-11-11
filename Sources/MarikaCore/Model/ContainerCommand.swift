import Foundation

public struct ContainerCommand: Sendable, Equatable {
    public var tool: String
    public var arguments: [String]
    public var timeout: Double
    public var environment: [String: String]
    public init(_ tool: String, _ arguments: [String], timeout: Double = 30, environment: [String: String] = [:]) {
        self.tool = tool; self.arguments = arguments; self.timeout = timeout; self.environment = environment
    }
    public var display: String { ([tool] + arguments).map(WorkspaceRuntime.quote).joined(separator: " ") }
}
public struct ContainerCommandResult: Sendable {
    public var status: Int32
    public var output: String
    public var error: String
    public init(status: Int32 = 0, output: String = "", error: String = "") { self.status = status; self.output = output; self.error = error }
    public var data: Data { Data(output.utf8) }
}
public struct ContainerHubError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct ContainerManifestReview: Sendable {
    public let data: Data
    public let source: String
    public let target: ContainerTarget
    public let namespace: String
    public let difference: String
}
