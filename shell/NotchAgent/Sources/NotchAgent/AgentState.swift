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
    /// True while ⌘ is held — set locally the moment the key goes down, then
    /// confirmed by the backend's own `mic` message.
    @Published var micOpen: Bool = false

    /// The panel opens on hover, and on its own while Claude is working so the
    /// activity feed is visible without having to park the cursor up there.
    var expanded: Bool { hovering || micOpen || phase == .thinking || approval != nil }

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
            assistantText = ""
            tools = []
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
