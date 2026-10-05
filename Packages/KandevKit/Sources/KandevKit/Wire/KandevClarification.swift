import Foundation

/// A question an agent has asked and cannot go on without the answer to.
///
/// It arrives as a **message** — one message per question, all sharing a pending id — because
/// that is how the server records it. The answer is one request for the whole bundle, so a
/// question of a three-question bundle is not answered on its own.
///
/// Verified against the server's clarification protocol and its own web client's types.
public struct KandevClarification: Sendable, Equatable {
    public struct Option: Sendable, Equatable, Identifiable {
        public var id: String
        public var label: String
        public var description: String

        public init(id: String, label: String, description: String = "") {
            self.id = id
            self.label = label
            self.description = description
        }
    }

    public enum Status: String, Sendable, Equatable {
        case pending
        case answered
        case rejected
        case expired
        case cancelled
    }

    /// The bundle this question belongs to. Shared by every question of one request.
    public var pendingID: String
    public var sessionID: String?
    public var taskID: String?
    public var questionID: String
    /// A short label for the question, at most a few words.
    public var title: String
    /// The question itself.
    public var prompt: String
    public var options: [Option]
    /// Whether the agent will also take an answer it did not offer.
    public var allowsCustomText: Bool
    /// Where this question sits in its bundle, and how many there are.
    public var index: Int?
    public var total: Int?
    /// Words shared by every question of the bundle.
    public var context: String?
    public var status: Status
    /// What was chosen, once it has been.
    public var answer: KandevClarificationAnswer?
    /// True when the agent has gone and the question can no longer be answered live.
    public var agentDisconnected: Bool

    /// Whether the question still wants an answer.
    public var isOpen: Bool { status == .pending && !agentDisconnected }

    /// How many questions the bundle holds, as the server counted them.
    ///
    /// One when it did not say: a request is at least one question, and a single question is the
    /// common case.
    public var bundleSize: Int { max(total ?? 1, 1) }
}

/// One question's answer, as the server takes it.
///
/// The route wants exactly one of these per question of the bundle, sent together, or none at
/// all when the bundle is rejected.
public struct KandevClarificationAnswer: Sendable, Codable, Equatable {
    public var questionID: String
    /// The chosen option ids. At most one for a single-choice question.
    public var selectedOptions: [String]
    /// An answer the agent did not offer, when the question allowed one.
    public var customText: String?

    public init(questionID: String, selectedOptions: [String] = [], customText: String? = nil) {
        self.questionID = questionID
        self.selectedOptions = selectedOptions
        self.customText = customText
    }

    enum CodingKeys: String, CodingKey {
        case questionID = "question_id"
        case selectedOptions = "selected_options"
        case customText = "custom_text"
    }
}

extension KandevClarification {
    /// Reads a question from the message that carries it, or nil for any other message.
    init?(message: KandevMessage) {
        guard message.type == "clarification_request",
              let metadata = message.metadata,
              let pendingID = metadata["pending_id"]?.stringValue,
              let question = metadata["question"],
              case let questionID? = question["id"]?.stringValue
        else { return nil }

        let options = (question["options"]?.arrayValue ?? []).compactMap { raw -> Option? in
            guard let id = raw["option_id"]?.stringValue else { return nil }
            return Option(
                id: id,
                label: raw["label"]?.stringValue ?? id,
                description: raw["description"]?.stringValue ?? ""
            )
        }

        self.init(
            pendingID: pendingID,
            sessionID: metadata["session_id"]?.stringValue,
            taskID: metadata["task_id"]?.stringValue,
            questionID: questionID,
            title: question["title"]?.stringValue ?? "",
            prompt: question["prompt"]?.stringValue ?? message.content ?? "",
            options: options,
            allowsCustomText: question["allow_custom_text"]?.boolValue ?? false,
            index: metadata["question_index"]?.intValue,
            total: metadata["question_total"]?.intValue,
            context: metadata["context"]?.stringValue,
            status: metadata["status"]?.stringValue.flatMap(Status.init(rawValue:)) ?? .pending,
            answer: metadata["response"].flatMap { response in
                guard let questionID = response["question_id"]?.stringValue else { return nil }
                return KandevClarificationAnswer(
                    questionID: questionID,
                    selectedOptions: (response["selected_options"]?.arrayValue ?? []).compactMap(\.stringValue),
                    customText: response["custom_text"]?.stringValue
                )
            },
            agentDisconnected: metadata["agent_disconnected"]?.boolValue ?? false
        )
    }
}
