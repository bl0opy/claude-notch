import Foundation
import SwiftUI

enum AgentPhase: String {
    case idle, listening, thinking, speaking, error, disconnected

    var label: String {
        switch self {
        case .idle: return "idle"
        case .listening: return "listening"
        case .thinking: return "thinking"
        case .speaking: return "speaking"
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
        case .error: return Color(red: 1.0, green: 0.38, blue: 0.38)
        }
    }
}

struct ToolEvent: Identifiable {
    let id = UUID()
    let name: String
    let summary: String
}

@MainActor
final class AgentState: ObservableObject {
    @Published var phase: AgentPhase = .disconnected
    @Published var userTranscript: String = ""
    @Published var assistantText: String = ""
    @Published var tools: [ToolEvent] = []
    @Published var sessionCwd: String = ""
    @Published var lastError: String = ""
    @Published var expanded: Bool = false

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
        case "tool":
            let name = message["name"] as? String ?? "tool"
            tools.append(ToolEvent(name: name, summary: message["summary"] as? String ?? ""))
            if tools.count > 6 { tools.removeFirst() }
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
    func send(text: String) { client?.send(["type": "text", "text": text]) }
}
