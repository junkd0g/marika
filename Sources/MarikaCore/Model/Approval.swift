import Foundation

/// A clarifying question from the agent, with the choices it offered.
public struct AgentQuestion: Equatable, Sendable, Identifiable {
    public struct Option: Equatable, Sendable, Identifiable {
        public var label: String
        public var detail: String
        /// What the agent gets back, when that differs from the label shown.
        public var value: String?

        public var id: String { label }
        public var answer: String { value ?? label }

        public init(label: String, detail: String = "", value: String? = nil) {
            self.label = label
            self.detail = detail
            self.value = value
        }
    }

    /// What a typed answer has to be, so bad input is caught before it's sent.
    public enum AnswerType: Equatable, Sendable {
        case text
        case integer
        case number
    }

    /// The key the answer is returned under.
    public var id: String
    public var header: String
    public var question: String
    public var options: [Option]
    public var allowsMultiple: Bool
    public var isOptional: Bool
    public var answerType: AnswerType
    /// False when only the listed options are valid.
    public var allowsFreeText: Bool
    /// Answers to start with. Each is an option's `answer`, or typed text.
    public var defaultAnswer: [String]
    public var minimum: Double?
    public var maximum: Double?

    public init(
        id: String, header: String, question: String, options: [Option], allowsMultiple: Bool = false,
        isOptional: Bool = false, answerType: AnswerType = .text, allowsFreeText: Bool = true,
        defaultAnswer: [String] = [], minimum: Double? = nil, maximum: Double? = nil
    ) {
        self.id = id
        self.header = header
        self.question = question
        self.options = options
        self.allowsMultiple = allowsMultiple
        self.isOptional = isOptional
        self.answerType = answerType
        self.allowsFreeText = allowsFreeText
        self.defaultAnswer = defaultAnswer
        self.minimum = minimum
        self.maximum = maximum
    }

    /// Why an answer can't be sent, in words for the card. Nil means it can.
    public func problem(with answer: [String]) -> String? {
        for value in answer {
            let number: Double?
            switch answerType {
            case .text:
                continue
            case .integer:
                guard let parsed = Int64(value) else { return "Enter a whole number." }
                number = Double(parsed)
            case .number:
                guard let parsed = Double(value), parsed.isFinite else { return "Enter a number." }
                number = parsed
            }
            if let number, let minimum, number < minimum { return "Enter \(Self.format(minimum)) or more." }
            if let number, let maximum, number > maximum { return "Enter \(Self.format(maximum)) or less." }
        }
        return nil
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }
}

/// How to show a link on a card, so the user can see where it really goes. Always built from the
/// parsed URL that will be opened: raw text can hold look-alike characters and text direction marks.
public struct LinkDisplay: Equatable, Sendable {
    public var host: String
    public var address: String
    public var warnings: [String]

    public init(_ url: URL) {
        let host = url.host ?? url.absoluteString
        self.host = host
        address = url.absoluteString
        var warnings: [String] = []
        if url.user != nil {
            warnings.append("The start of this address is a user name, not the site. It goes to \(host).")
        }
        if host.lowercased().split(separator: ".").contains(where: { $0.hasPrefix("xn--") }) {
            warnings.append("This address uses non-Latin characters, which can imitate another site.")
        }
        self.warnings = warnings
    }
}

/// A way to stop being asked about similar actions.
public struct RememberOption: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    /// Agent-specific data returned with the decision.
    public var payload: JSONValue

    public init(id: String, label: String, payload: JSONValue) {
        self.id = id
        self.label = label
        self.payload = payload
    }
}

/// The agent is paused until the user answers.
public struct ApprovalRequest: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case tool
        case questions([AgentQuestion])
        case plan(String)
    }

    public var id: String
    public var kind: Kind
    public var toolCallID: String?
    public var toolKind: ToolKind
    public var title: String
    public var detail: String
    public var reason: String?
    public var diff: [DiffFile]
    public var input: JSONValue
    public var rememberOptions: [RememberOption]
    /// Plain facts about what Allow really means, shown on the card.
    public var notes: [String]
    /// Set when the action runs somewhere other than the project folder.
    public var workingDirectory: String?
    /// Which sub-agent is asking, when it isn't the main agent.
    public var agentLabel: String?
    /// A web page the user is being asked to open.
    public var link: URL?

    public init(
        id: String, kind: Kind = .tool, toolCallID: String? = nil, toolKind: ToolKind = .other, title: String,
        detail: String = "", reason: String? = nil, diff: [DiffFile] = [], input: JSONValue = .object([:]),
        rememberOptions: [RememberOption] = [], notes: [String] = [], workingDirectory: String? = nil,
        agentLabel: String? = nil, link: URL? = nil
    ) {
        self.id = id
        self.kind = kind
        self.toolCallID = toolCallID
        self.toolKind = toolKind
        self.title = title
        self.detail = detail
        self.reason = reason
        self.diff = diff
        self.input = input
        self.rememberOptions = rememberOptions
        self.notes = notes
        self.workingDirectory = workingDirectory
        self.agentLabel = agentLabel
        self.link = link
    }
}

public enum ApprovalDecision: Sendable, Equatable {
    case allow(remember: RememberOption? = nil)
    /// Stop the turn and wait for the user's next instruction.
    case deny
    /// Refuse this action, but carry on with this guidance.
    case denyWithFeedback(String)
    /// Leave a question unanswered and let the turn carry on.
    case skip
    /// Answers keyed by question id. Each value is one or more selected labels, or typed text.
    case answers([String: [String]])
    /// Approve a plan, optionally switching how the work then runs.
    case approvePlan(then: ApprovalMode?)
}
