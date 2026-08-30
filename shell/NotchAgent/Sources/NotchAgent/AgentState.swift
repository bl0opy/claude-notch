import Foundation
import SwiftUI

enum AgentPhase: String {
    case idle, listening, thinking, speaking, waiting, error, disconnected

    var label: String {
        switch self {
        case .idle: return "idle"
        case .listening: return "listening"
        case .thinking: return "thinking"
        case .speaking: return "speaking"
        case .waiting: return "waiting on you"
        case .error: return "error"
        case .disconnected: return "offline"
        }
    }

    var tint: Color {
        switch self {
        case .idle, .disconnected: return Color(white: 0.45)
        case .listening: return Color(red: 0.36, green: 0.85, blue: 0.55)
        case .thinking: return Color(red: 0.98, green: 0.78, blue: 0.32)
        case .speaking: return Color(red: 0.40, green: 0.68, blue: 1.0)
        case .waiting: return Color(red: 0.98, green: 0.62, blue: 0.28)
        case .error: return Color(red: 1.0, green: 0.38, blue: 0.38)
        }
    }
}

/// A tool call parked on the user's answer, mirrored from the PreToolUse hook.
struct ApprovalRequest: Identifiable {
    let id: String
    let tool: String
    let reason: String
}

struct ToolEvent: Identifiable {
    enum Status { case running, done, failed }

    /// Claude Code's own tool_use id, so the matching tool_result can find this row.
    let id: String
    let name: String
    let summary: String
    let detail: String
    var status: Status = .running
}

/// The panel shows one thing at a time: the agent you're talking to, or all of them.
enum PanelMode: String {
    case focus, agents
}

@MainActor
final class AgentState: ObservableObject {
    @Published var phase: AgentPhase = .disconnected
    @Published var userTranscript: String = ""
    @Published var assistantText: String = ""
    @Published var tools: [ToolEvent] = []
    @Published var sessionCwd: String = ""
    @Published var lastError: String = ""
    @Published var approval: ApprovalRequest?
    @Published var hovering: Bool = false
    /// True while the push-to-talk key is held — set locally the moment the key goes down, then
    /// confirmed by the backend's own `mic` message.
    @Published var micOpen: Bool = false
    /// Every claude session on the machine, worst state first.
    @Published var agents: [RemoteAgent] = []
    /// The one that hears the mic and speaks. nil = the voice agent's own session.
    @Published var focused: String?
    @Published var rosterDegraded: Bool = false
    /// Sessions the voice backend started, which is what makes them interruptible.
    @Published var ownedIds: Set<String> = []
    /// Which half of the panel is showing.
    @Published var panel: PanelMode = .focus
    /// Held open regardless of the cursor — click the notch to pin it, which is
    /// what makes the dashboard usable while you work somewhere else.
    @Published var pinned: Bool = false
    /// Whether the agents daemon is answering at all, which is a different thing
    /// from there being no agents.
    @Published var rosterConnected: Bool = false

    /// A foreign agent — one started in a terminal — can be talked to but not
    /// interrupted, and its permission questions are answered where it runs.
    var canInterrupt: Bool {
        guard let focused else { return true }
        if ownedIds.contains(focused) { return true }
        guard let agent = agents.first(where: { $0.id == focused }) else { return true }
        return agent.owned
    }

    /// The panel opens on hover, and on its own while Claude is working so the
    /// activity feed is visible without having to park the cursor up there.
    var expanded: Bool { hovering || pinned || micOpen || phase == .thinking || approval != nil }

    private var client: BridgeClient?

    func attach(_ client: BridgeClient) {
        self.client = client
    }

    func apply(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        switch type {
        case "state":
            if let value = message["value"] as? String, let next = AgentPhase(rawValue: value) {
                phase = next
                if next == .thinking { assistantText = "" }
            }
        case "transcript":
            userTranscript = message["text"] as? String ?? ""
            // Partials land while the key is still held — the turn isn't sent
            // yet, so the last answer stays up until it is.
            if message["final"] as? Bool ?? true {
                assistantText = ""
                tools = []
                panel = .focus
            }
        case "assistant_delta":
            assistantText += message["text"] as? String ?? ""
        case "assistant_done":
            if let text = message["text"] as? String, !text.isEmpty { assistantText = text }
        case "approval":
            approval = ApprovalRequest(
                id: message["id"] as? String ?? "",
                tool: message["tool"] as? String ?? "tool",
                reason: message["reason"] as? String ?? ""
            )
        case "approval_closed":
            approval = nil
        case "tool":
            let event = ToolEvent(
                id: message["id"] as? String ?? UUID().uuidString,
                name: message["name"] as? String ?? "tool",
                summary: message["summary"] as? String ?? "",
                detail: message["detail"] as? String ?? ""
            )
            tools.append(event)
            if tools.count > 8 { tools.removeFirst() }
        case "tool_result":
            guard let id = message["id"] as? String,
                  let index = tools.firstIndex(where: { $0.id == id }) else { return }
            tools[index].status = (message["ok"] as? Bool ?? true) ? .done : .failed
        case "agents":
            let rows = (message["list"] as? [[String: Any]] ?? []).compactMap(RemoteAgent.init)
            agents = rows.sorted {
                ($0.state.rank, $0.project) < ($1.state.rank, $1.project)
            }
            rosterDegraded = message["degraded"] as? Bool ?? false
        case "focus":
            focused = message["id"] as? String
        case "owned":
            ownedIds = Set(message["ids"] as? [String] ?? [])
        case "mic":
            micOpen = message["open"] as? Bool ?? false
        case "session":
            sessionCwd = message["cwd"] as? String ?? ""
        case "error":
            lastError = message["message"] as? String ?? ""
            phase = .error
        default:
            break
        }
    }

    func interrupt() { client?.send(["type": "interrupt"]) }
    func focus(_ id: String) {
        focused = id
        client?.send(["type": "focus", "id": id])
    }
    /// The agents daemon dropped: empty the roster rather than show a frozen one.
    func clearRoster() {
        agents = []
        rosterDegraded = false
        rosterConnected = false
    }

    func show(_ mode: PanelMode) {
        panel = mode
        pinned = true
    }

    /// Start a new agent in a directory of your choosing, owned by the notch.
    func startAgent(in cwd: String) {
        client?.send(["type": "start_agent", "cwd": cwd])
    }
    func setTalking(_ down: Bool) {
        micOpen = down
        client?.send(["type": "ptt", "down": down])
    }
    func answerApproval(_ approved: Bool) {
        client?.send(["type": "approve", "approved": approved])
        approval = nil
    }
    func send(text: String) { client?.send(["type": "text", "text": text]) }
}
