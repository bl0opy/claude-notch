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
    /// Started by the notch: it can be interrupted, and its permission questions
    /// can be answered here. A session started in a terminal can't be.
    let owned: Bool
    /// Has a messaging socket, so it can be talked to at all.
    let reachable: Bool
    let pid: Int
    /// Where it runs: "ttys003" in "Terminal". Blank when the daemon couldn't tell.
    let tty: String
    let host: String
    /// A Code tab in the Claude app: its title there, and the app's own line
    /// about what the last turn did and what it needs from you.
    let appTitle: String
    let summary: String
    let needs: String
    /// Opens it in the app.
    let link: String

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
        appTitle = raw["title"] as? String ?? ""
        summary = raw["summary"] as? String ?? ""
        needs = raw["needs"] as? String ?? ""
        link = raw["link"] as? String ?? ""
    }

    /// Runs in the agents daemon's pty; its terminal is the notch's own window.
    var hosted: Bool { host == "window" }
    var desktop: Bool { host == "desktop" }
    var canJump: Bool { hosted || (desktop && !link.isEmpty) || Jump.canJump(host: host) }

    /// What to call it in a list: the app's title for it, or where it is.
    var label: String { appTitle.isEmpty ? title : appTitle }

    /// Where it is: `voice-agent/main`.
    var title: String { branch.isEmpty ? project : "\(project)/\(branch)" }

    /// What it's doing, in the same words the activity feed uses.
    var subtitle: String {
        switch state {
        case .waiting:
            if !needs.isEmpty { return needs }
            return waitingFor.isEmpty ? "waiting on you" : "waiting: \(waitingFor)"
        case .working:
            if activity.isEmpty { return "working" }
            return activityDetail.isEmpty ? activity : "\(activity)(\(activityDetail))"
        case .idle: return summary.isEmpty ? "idle" : summary
        case .unknown: return "—"
        }
    }
}

/// One line of a session's conversation, as the agents daemon reads it back.
struct ChatRow: Identifiable, Equatable {
    enum Role: String { case you, claude, tool, notch }

    let id: Int
    let role: Role
    let text: String

    init?(_ raw: [String: Any], index: Int) {
        guard let role = Role(rawValue: raw["role"] as? String ?? ""),
              let text = raw["text"] as? String, !text.isEmpty else { return nil }
        id = index
        self.role = role
        self.text = text
    }
}
