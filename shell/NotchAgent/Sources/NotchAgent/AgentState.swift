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
    /// Every session's open permission question, oldest first.
    @Published var approvals: [ApprovalRequest] = []
    /// Questions you've waved away for now. The panel stops opening for them,
    /// and opens again for the next new one.
    @Published var snoozed: Set<String> = []
    @Published var hovering: Bool = false { didSet { settle() } }
    /// True while the push-to-talk key is held — set locally the moment the key goes down, then
    /// confirmed by the backend's own `mic` message.
    @Published var micOpen: Bool = false
    /// Every claude session on the machine, worst state first.
    @Published var agents: [RemoteAgent] = []
    /// The one that hears the mic and speaks. nil = the voice agent's own session.
    @Published var focused: String?
    @Published var rosterDegraded: Bool = false
    @Published var fleetTotals: FleetTotals? = nil
    /// Sessions the voice backend started, which is what makes them interruptible.
    @Published var ownedIds: Set<String> = []
    /// Which half of the panel is showing.
    @Published var panel: PanelMode = .focus
    /// Whether the agents daemon is answering at all, which is a different thing
    /// from there being no agents.
    @Published var rosterConnected: Bool = false

    /// A foreign agent — one started in a terminal — can be talked to and
    /// approved, but not interrupted.
    var canInterrupt: Bool {
        guard let focused else { return true }
        if ownedIds.contains(focused) { return true }
        guard let agent = agents.first(where: { $0.id == focused }) else { return true }
        return agent.owned
    }

    /// The panel is only ever open under the cursor, or while the talk key is
    /// held. Work in progress shows as the pill instead, which is enough to see
    /// Claw'd without the panel covering what you're doing.
    var expanded: Bool { hovering || micOpen }

    /// Folded into the hardware notch: nothing is working, waiting or talking,
    /// and hasn't been for a few seconds. Hover the notch to bring it back.
    @Published private(set) var dormant = false
    /// When the fleet last had something going on.
    @Published private(set) var lastBusy = Date()

    /// Anything that deserves the notch being visible.
    var busy: Bool {
        if micOpen || !approvals.isEmpty { return true }
        if [.thinking, .speaking, .waiting, .error].contains(phase) { return true }
        return agents.contains { $0.state == .working || $0.state == .waiting }
    }

    var mood: CrabMood {
        if phase == .error { return .error }
        if micOpen { return .listening }
        if phase == .speaking { return .speaking }
        if !approvals.isEmpty || phase == .waiting || agents.contains(where: { $0.state == .waiting }) {
            return .waiting
        }
        if phase == .thinking || agents.contains(where: { $0.state == .working }) { return .thinking }
        return Date().timeIntervalSince(lastBusy) > Self.sleepAfter ? .asleep : .idle
    }

    private static let foldAfter: TimeInterval = 8
    private static let sleepAfter: TimeInterval = 45
    private var clock: Timer?

    /// Re-judges dormancy once a second; the inputs arrive over two sockets and
    /// the answer also depends on how long it's been quiet.
    func startClock() {
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.settle() }
        }
    }

    func settle() {
        let now = Date()
        if busy { lastBusy = now }
        let fold = !busy && !hovering && now.timeIntervalSince(lastBusy) > Self.foldAfter
        if fold != dormant { dormant = fold }
    }

    var unseenApprovals: [ApprovalRequest] { approvals.filter { !snoozed.contains($0.id) } }

    /// The one ⌃⌥Y / ⌃⌥N / ⌃⌥J act on.
    var topApproval: ApprovalRequest? { approvals.first }

    private var client: BridgeClient?
    /// The agents daemon holds the approvals, so answers go there, not to the voice backend.
    private var fleet: BridgeClient?

    func attach(_ client: BridgeClient, fleet: BridgeClient) {
        self.client = client
        self.fleet = fleet
    }

    func agent(for request: ApprovalRequest) -> RemoteAgent? {
        agents.first { $0.id == request.sessionId } ?? agents.first { $0.pid == request.pid && request.pid > 0 }
    }

    func apply(_ message: [String: Any]) {
        defer { settle() }
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
        case "approvals":
            approvals = (message["list"] as? [[String: Any]] ?? []).compactMap(ApprovalRequest.init)
            snoozed.formIntersection(approvals.map(\.id))
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
            fleetTotals = FleetTotals(message["fleet"] as? [String: Any])
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
        approvals = []
        rosterDegraded = false
        rosterConnected = false
        fleetTotals = nil
    }

    func show(_ mode: PanelMode) {
        panel = mode
    }

    /// Start a new agent in a directory of your choosing, owned by the notch.
    func startAgent(in cwd: String) {
        client?.send(["type": "start_agent", "cwd": cwd])
    }
    func setTalking(_ down: Bool) {
        micOpen = down
        client?.send(["type": "ptt", "down": down])
    }
    func answer(_ request: ApprovalRequest, approved: Bool, always: Bool = false) {
        fleet?.send(["type": "approve", "id": request.id, "approved": approved, "always": always, "how": "from the notch"])
        // The daemon's next snapshot confirms it; don't leave the card up meanwhile.
        approvals.removeAll { $0.id == request.id }
    }

    func snoozeApprovals() {
        snoozed.formUnion(approvals.map(\.id))
    }

    func jump(to request: ApprovalRequest) {
        if let agent = agent(for: request) { jump(to: agent) }
    }

    func jump(to agent: RemoteAgent) {
        Jump.to(host: agent.host, tty: agent.tty)
    }

    /// Cut one agent off mid-turn — only the notch's own can be.
    func stop(_ agent: RemoteAgent) {
        client?.send(["type": "interrupt", "id": agent.id])
    }
    func send(text: String) { client?.send(["type": "text", "text": text]) }
}
