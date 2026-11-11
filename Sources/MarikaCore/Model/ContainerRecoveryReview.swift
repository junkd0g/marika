import Foundation

public struct ContainerRevision: Identifiable, Sendable {
    public var id: Int { revision }
    public let revision: Int
    public let name: String
    public let uid: String
    public let images: String
    public let template: JSONValue
}

public struct ContainerRecoveryReview: Identifiable, Sendable {
    public enum Kind: Sendable { case retry, rollback }
    public let id = UUID()
    public let kind: Kind
    public let source: ContainerResource
    public let target: ContainerTarget
    public let title: String
    public let explanation: String
    public let before: String
    public let after: String
    public let sourceSpec: JSONValue
    public let newJobName: String?
    public let jobData: Data?
    public let revision: ContainerRevision?
    init(kind: Kind, source: ContainerResource, target: ContainerTarget, title: String, explanation: String, before: String, after: String,
         sourceSpec: JSONValue, newJobName: String? = nil, jobData: Data? = nil, revision: ContainerRevision? = nil) {
        self.kind = kind; self.source = source; self.target = target; self.title = title; self.explanation = explanation
        self.before = before; self.after = after; self.sourceSpec = sourceSpec; self.newJobName = newJobName; self.jobData = jobData; self.revision = revision
    }
}
