import Foundation

/// A tool call some session is parked on, from the agents daemon's inbox.
///
/// `terminal` ones also have Claude Code's own dialog up in their terminal —
/// answering in either place closes both. `owned` ones are the notch's own
/// agents, where nobody answering means no.
struct ApprovalRequest: Identifiable, Equatable {
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
        created = Date(timeIntervalSince1970: (raw["created"] as? Double ?? 0) / 1000)
    }

    var title: String { project.isEmpty ? tool : "\(project) · \(tool)" }
}
