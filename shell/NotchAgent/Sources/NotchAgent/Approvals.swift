import Foundation

/// A tool call some session is parked on, from the agents daemon's inbox.
///
/// `terminal` ones also have Claude Code's own dialog up in their terminal —
/// answering in either place closes both. `owned` ones are the notch's own
/// agents, where nobody answering means no.
struct ApprovalRequest: Identifiable, Equatable {
    /// One of Claude's multiple-choice questions.
    struct Question: Equatable {
        struct Option: Equatable {
            let label: String
            let description: String
        }

        let text: String
        let header: String
        let options: [Option]
        let multiSelect: Bool

        init?(_ raw: [String: Any]) {
            guard let text = raw["question"] as? String, !text.isEmpty else { return nil }
            self.text = text
            header = raw["header"] as? String ?? ""
            multiSelect = raw["multiSelect"] as? Bool ?? false
            options = (raw["options"] as? [[String: Any]] ?? []).compactMap {
                guard let label = $0["label"] as? String else { return nil }
                return Option(label: label, description: $0["description"] as? String ?? "")
            }
        }
    }

    let id: String
    let source: String
    let sessionId: String
    let pid: Int
    let project: String
    let tool: String
    /// The command, path or URL, verbatim.
    let detail: String
    /// "push to git" — what gets said out loud.
    let summary: String
    /// Destructive enough that a bare "yes" by voice won't do.
    let risky: Bool
    /// Claude Code offered a rule for it, so "always" is possible.
    let canAlways: Bool
    /// The rule "always" adds, as Claude Code writes it: `Bash(npm test:*)`.
    let always: String
    /// What the agent said before asking, or what it was asked.
    let why: String
    /// Asked for with "why?": what the call does, while the question stays open.
    let explanation: String
    let explaining: Bool
    /// Not empty: Claude is asking you to choose, not asking to be allowed.
    let questions: [Question]
    let created: Date

    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        source = raw["source"] as? String ?? "terminal"
        sessionId = raw["sessionId"] as? String ?? ""
        pid = raw["pid"] as? Int ?? 0
        project = raw["project"] as? String ?? ""
        tool = raw["tool"] as? String ?? "tool"
        detail = raw["detail"] as? String ?? ""
        summary = raw["summary"] as? String ?? ""
        risky = raw["risky"] as? Bool ?? false
        canAlways = raw["canAlways"] as? Bool ?? false
        always = raw["always"] as? String ?? ""
        why = raw["why"] as? String ?? ""
        explanation = raw["explanation"] as? String ?? ""
        explaining = raw["explaining"] as? Bool ?? false
        questions = (raw["questions"] as? [[String: Any]] ?? []).compactMap(Question.init)
        created = Date(timeIntervalSince1970: (raw["created"] as? Double ?? 0) / 1000)
    }

    var title: String { project.isEmpty ? tool : "\(project) · \(tool)" }
}
