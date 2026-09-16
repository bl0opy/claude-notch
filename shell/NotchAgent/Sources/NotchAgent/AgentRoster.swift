import SwiftUI

/// One Claude Code session somewhere on the machine, as the agents daemon sees it.
struct RemoteAgent: Identifiable, Equatable {
    enum State: String {
        case working, waiting, idle, unknown

        var tint: Color {
            switch self {
            case .working: return AgentPhase.thinking.tint
            case .waiting: return AgentPhase.waiting.tint
            case .idle, .unknown: return Color(white: 0.45)
            }
        }

        /// Worst-first, so the row that needs you sorts to the top.
        var rank: Int {
            switch self {
            case .waiting: return 0
            case .working: return 1
            case .idle: return 2
            case .unknown: return 3
            }
        }
    }

    let id: String
    let project: String
    let branch: String
    let state: State
    let waitingFor: String
    let activity: String
    let activityDetail: String
    let tokensOut: Int
    let subagents: Int
    /// Started by the notch: it can be interrupted, and its permission questions
    /// can be answered here. A session started in a terminal can't be.
    let owned: Bool
    /// Has a messaging socket, so it can be talked to at all.
    let reachable: Bool
    let pid: Int
    /// Where it runs: "ttys003" in "Terminal". Blank when the daemon couldn't tell.
    let tty: String
    let host: String

    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        project = raw["project"] as? String ?? ""
        let rawBranch = raw["branch"] as? String ?? ""
        branch = rawBranch == "HEAD" ? "" : rawBranch
        state = State(rawValue: raw["state"] as? String ?? "") ?? .unknown
        waitingFor = raw["waitingFor"] as? String ?? ""
        activity = raw["activity"] as? String ?? ""
        activityDetail = raw["activityDetail"] as? String ?? ""
        owned = raw["owned"] as? Bool ?? false
        reachable = raw["reachable"] as? Bool ?? false
        pid = raw["pid"] as? Int ?? 0
        tty = raw["tty"] as? String ?? ""
        host = raw["host"] as? String ?? ""
        subagents = (raw["subagents"] as? [String: Any])?["total"] as? Int ?? 0
        tokensOut = (raw["tokens"] as? [String: Any])?["out"] as? Int ?? 0
    }

    var canJump: Bool { Jump.canJump(host: host) }

    /// Where it is: `voice-agent/main`.
    var title: String { branch.isEmpty ? project : "\(project)/\(branch)" }

    /// What it's doing, in the same words the activity feed uses.
    var subtitle: String {
        switch state {
        case .waiting: return waitingFor.isEmpty ? "waiting on you" : "waiting: \(waitingFor)"
        case .working:
            if activity.isEmpty { return "working" }
            return activityDetail.isEmpty ? activity : "\(activity)(\(activityDetail))"
        case .idle: return "idle"
        case .unknown: return "—"
        }
    }
}

/// 812 · 4.2k · 1.4M — narrow and stable so the column doesn't jitter.
func compactTokens(_ value: Int) -> String {
    switch value {
    case ..<1_000: return "\(value)"
    case ..<1_000_000: return String(format: "%.1fk", Double(value) / 1_000)
    default: return String(format: "%.1fM", Double(value) / 1_000_000)
    }
}
