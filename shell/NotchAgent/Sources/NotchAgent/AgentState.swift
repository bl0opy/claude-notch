import AppKit
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

/// A line about an agent you aren't talking to: how a long turn is going, that
/// it looks stuck, or that it's finished. Shown in the notch for a few seconds.
struct Notice: Identifiable, Equatable {
    enum Kind: String { case progress, stuck, done }

    let id = UUID()
    let sessionId: String
    let project: String
    let line: String
    let kind: Kind

    var attention: Bool { kind == .stuck }

    /// Long enough to read a sentence; a stuck agent stays up a little longer.
    var lifetime: Duration { attention ? .seconds(14) : .seconds(9) }

    /// "done after 4 minutes", in the words the notice reads out.
    static func doneLine(project: String, seconds: Int) -> String {
        let name = project.isEmpty ? "An agent" : project
        guard seconds >= 60 else { return "\(name) done after \(max(seconds, 1)) seconds" }
        let minutes = seconds / 60
        return "\(name) done after \(minutes) minute\(minutes == 1 ? "" : "s")"
    }
}

@MainActor
final class AgentState: ObservableObject {
    /// Voice in and out, from settings.json at launch. Off, there's no voice
    /// backend and the notch is typed to.
    let voice = Settings.voice
    /// Agents started from the notch, in its own terminal window. Read at launch.
    let hostedAgents = Settings.hostedAgents
    @Published var phase: AgentPhase = Settings.voice ? .disconnected : .idle
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
    /// Put away because the Claude app isn't open. Sessions keep being watched,
    /// so it's current the moment it comes back.
    private(set) var hidden = false
    @Published var hovering: Bool = false {
        didSet {
            // Moving over the lingering panel and away is how you dismiss it.
            if oldValue && !hovering { lingering = false }
            settle()
        }
    }
    /// True while the push-to-talk key is held — set locally the moment the key goes down, then
    /// confirmed by the backend's own `mic` message.
    @Published var micOpen: Bool = false {
        didSet {
            if oldValue && !micOpen {
                lingering = true
                quietSince = nil
            }
        }
    }
    /// Every claude session on the machine, worst state first.
    @Published var agents: [RemoteAgent] = []
    /// The one that hears the mic and speaks. nil = the voice agent's own session.
    @Published var focused: String?
    @Published var rosterDegraded: Bool = false
    /// Sessions the voice backend started, which is what makes them interruptible.
    @Published var ownedIds: Set<String> = []
    /// Whether the agents daemon is answering at all, which is a different thing
    /// from there being no agents.
    @Published var rosterConnected: Bool = false
    /// The supervisor's latest word, while it's showing.
    @Published var notice: Notice?
    private var noticeTimer: Task<Void, Never>?

    /// True while a field in the notch has the keyboard — the compose line or
    /// the new-agent path: the panel stays open with the cursor elsewhere,
    /// since you're mid-sentence.
    @Published var composing: Bool = false
    /// The agents tab's inline "+ agent" path field is open.
    @Published var addingAgent: Bool = false
    @Published var newAgentRequest: Int = 0
    /// Bumped to pull the keyboard into the compose field (⌃⌥T), and to let
    /// go of it when the notch stops being the key window.
    @Published var composeRequest: Int = 0
    @Published var composeDismiss: Int = 0
    /// The target session's conversation so far, refreshed while the panel is open.
    @Published var chat: [ChatRow] = []
    @Published var chatFor: String?
    private var chatAsked = Date.distantPast
    private static let chatEvery: TimeInterval = 2

    /// What became of the last typed line, while it's worth showing.
    @Published var typedStatus: String = ""
    private var typedTarget: String?
    private var typedTimer: Task<Void, Never>?

    /// Who a typed line goes to. With voice, nil is the voice agent's own
    /// session; typing only, there's no such thing, so it's the chosen row, or
    /// failing that the one most likely to be wanted.
    var target: RemoteAgent? {
        if let focused, let agent = agents.first(where: { $0.id == focused }) { return agent }
        if voice { return nil }
        return agents.first(where: \.hosted) ?? agents.first
    }

    var targetName: String {
        if let target { return target.title.isEmpty ? "that agent" : target.title }
        return voice ? "the voice agent" : "an agent"
    }

    /// A foreign agent — one started in a terminal — can be talked to and
    /// approved, but not interrupted.
    var canInterrupt: Bool {
        if !voice { return target?.hosted ?? false }
        guard let focused else { return true }
        if ownedIds.contains(focused) { return true }
        guard let agent = agents.first(where: { $0.id == focused }) else { return true }
        return agent.owned
    }

    /// The panel is only ever open under the cursor, or while the talk key is
    /// held, and a little after. Work in progress shows as the pill instead, which is enough to see
    /// Claw'd without the panel covering what you're doing.
    var expanded: Bool { hovering || micOpen || lingering || composing }

    /// What the island is showing: folded away, the pill, a notice, a
    /// question, or the panel. A question you haven't hidden outranks a notice.
    var islandMode: IslandMode {
        if expanded { return .expanded }
        if !unseenApprovals.isEmpty { return .question }
        if notice != nil { return .notice }
        return dormant ? .dormant : .compact
    }

    /// After the talk key comes up the panel stays open through the reply and
    /// a few seconds past it, so you can read what it heard and what it said.
    @Published private(set) var lingering = false
    private var quietSince: Date?
    private static let lingerAfterReply: TimeInterval = 6

    /// Folded into the hardware notch: nothing is working, waiting or talking,
    /// and hasn't been for `Settings.foldAfter` seconds. Hover the notch to bring it back.
    @Published private(set) var dormant = false
    /// When the fleet last had something going on.
    @Published private(set) var lastBusy = Date()

    /// Anything that deserves the notch being visible.
    var busy: Bool {
        if micOpen || !approvals.isEmpty || notice != nil { return true }
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

    private static let sleepAfter: TimeInterval = 45
    private var clock: Timer?

    /// Re-judges dormancy once a second; the inputs arrive over two sockets and
    /// the answer also depends on how long it's been quiet.
    func startClock() {
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.settle() }
        }
    }

    func setHidden(_ value: Bool) {
        hidden = value
        if value {
            hovering = false
            endCompose()
        } else {
            // Coming back is news: stay out as the pill, not folded away.
            lastBusy = Date()
            settle()
        }
    }

    func settle() {
        let now = Date()
        if busy { lastBusy = now }
        let fold = !busy && !hovering && now.timeIntervalSince(lastBusy) > Settings.foldAfter
        if fold != dormant { dormant = fold }

        if expanded, now.timeIntervalSince(chatAsked) >= Self.chatEvery { refreshChat() }

        if lingering {
            if micOpen || [.listening, .thinking, .speaking].contains(phase) {
                quietSince = nil
            } else if let quietSince, now.timeIntervalSince(quietSince) > Self.lingerAfterReply {
                lingering = false
            } else if quietSince == nil {
                quietSince = now
            }
        }
    }

    var unseenApprovals: [ApprovalRequest] { approvals.filter { !snoozed.contains($0.id) } }

    /// The one ⌃⌥Y / ⌃⌥N / ⌃⌥J act on.
    var topApproval: ApprovalRequest? { approvals.first }

    private var client: MessageSink?
    /// The agents daemon holds the approvals, so answers go there, not to the voice backend.
    private var fleet: MessageSink?

    func attach(_ client: MessageSink, fleet: MessageSink) {
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
            }
        case "assistant_delta":
            assistantText += message["text"] as? String ?? ""
        case "assistant_done":
            if let text = message["text"] as? String, !text.isEmpty { assistantText = text }
        case "approvals":
            let before = Set(approvals.map(\.id))
            approvals = (message["list"] as? [[String: Any]] ?? []).compactMap(ApprovalRequest.init)
            snoozed.formIntersection(approvals.map(\.id))
            // The first list after connecting is what was already waiting, not news.
            if approvalsLoaded, approvals.contains(where: { !before.contains($0.id) }) { chime(.attention) }
            approvalsLoaded = true
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
        case "fleet_event":
            post(message)
        case "typed":
            guard let id = message["id"] as? String, id == typedTarget else { return }
            showTyped(message["status"] as? String ?? "", detail: message["detail"] as? String ?? "")
        case "spawned":
            // A session the agents daemon just started (or resumed): show it.
            if Settings.hostedAgents, let id = message["id"] as? String { TerminalWindow.shared.show(session: id) }
        case "chat":
            guard let id = message["id"] as? String, id == target?.id else { return }
            let rows = message["rows"] as? [[String: Any]] ?? []
            let next = rows.enumerated().compactMap { ChatRow($1, index: $0) }
            if next != chat || chatFor != id { chat = next }
            chatFor = id
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

    /// With voice, lines about the agent you're talking to are noise: you can
    /// hear it. Typing, you can't, so every agent's news shows. A turn's end
    /// shows only when it ran long enough that you'd have looked away.
    private func post(_ message: [String: Any]) {
        guard let raw = message["event"] as? String, let kind = Notice.Kind(rawValue: raw),
              let sessionId = message["sessionId"] as? String else { return }
        if voice, sessionId == focused { return }
        let project = message["project"] as? String ?? ""
        let line: String
        switch kind {
        case .done:
            guard message["long"] as? Bool ?? false else { return }
            let said = message["line"] as? String ?? ""
            line = said.isEmpty
                ? Notice.doneLine(project: project, seconds: message["seconds"] as? Int ?? 0)
                : "Done: \(said)"
        case .progress, .stuck:
            line = message["line"] as? String ?? ""
        }
        guard !line.isEmpty else { return }
        // Nothing covers a stuck agent's line while it's still being read.
        if let current = notice, current.attention, kind != .stuck { return }
        let next = Notice(sessionId: sessionId, project: project, line: line, kind: kind)
        notice = next
        if kind != .progress { chime(kind == .done ? .done : .attention) }
        noticeTimer?.cancel()
        noticeTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: next.lifetime)
            guard !Task.isCancelled, self?.notice?.id == next.id else { return }
            self?.notice = nil
            self?.settle()
        }
    }

    enum Chime: String {
        case done = "Glass", attention = "Ping"
    }

    /// Voice speaks news out loud; typing only, a system sound stands in for it.
    /// Set `sounds` in settings.json to turn it on or off either way.
    var play: (Chime) -> Void = { NSSound(named: NSSound.Name($0.rawValue))?.play() }
    private var approvalsLoaded = false
    private func chime(_ sound: Chime) {
        guard !hidden, Settings.sounds(voice: voice) else { return }
        play(sound)
    }

    func dismissNotice() {
        noticeTimer?.cancel()
        notice = nil
    }

    /// Go to the agent a notice is about: its terminal, or the terminal window.
    func open(_ notice: Notice) {
        dismissNotice()
        if let agent = agents.first(where: { $0.id == notice.sessionId }) { jump(to: agent) }
    }

    func interrupt() {
        if let target, target.hosted {
            fleet?.send(["type": "interrupt", "id": target.id])
        } else {
            client?.send(["type": "interrupt"])
        }
    }
    func focus(_ id: String) {
        focused = id
        client?.send(["type": "focus", "id": id])
        refreshChat()
    }

    /// Ask the daemon for the target's conversation; the reply lands as `chat`.
    func refreshChat() {
        chatAsked = Date()
        guard let id = target?.id else {
            chat = []
            chatFor = nil
            return
        }
        if chatFor != id { chat = [] }
        fleet?.send(["type": "chat", "id": id])
    }
    /// The agents daemon dropped: empty the roster rather than show a frozen one.
    func clearRoster() {
        approvalsLoaded = false
        agents = []
        approvals = []
        rosterDegraded = false
        rosterConnected = false
    }

    /// Start Claude Code in a directory of your choosing, hosted by the agents
    /// daemon and shown in the terminal window.
    func startAgent(in cwd: String) {
        fleet?.send(["type": "spawn", "cwd": cwd])
    }

    /// Open the inline path field for a new hosted agent (+ in the session row).
    func requestNewAgent() {
        takeKeyboard()
        addingAgent = true
        composing = true
        newAgentRequest += 1
    }

    /// What's typed in the path field: started, or why not.
    func submitNewAgent(_ typed: String) -> String? {
        let path = AgentPath.resolve(typed)
        guard AgentPath.isDirectory(path) else { return "no folder at \(path)" }
        guard rosterConnected else { return "the agents daemon isn't running" }
        startAgent(in: path)
        addingAgent = false
        return nil
    }

    func cancelNewAgent() {
        addingAgent = false
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

    /// Neither yes nor no yet: the agent is told to explain itself and ask
    /// again. Claude Code reads a deny's message and carries on with the turn.
    static let askWhy = "The user hasn't decided yet and wants to know why first. "
        + "In a sentence or two, say what this is for and what happens if it's skipped, then try it again."

    func ask(_ request: ApprovalRequest) {
        fleet?.send(["type": "approve", "id": request.id, "approved": false, "always": false, "how": Self.askWhy])
        approvals.removeAll { $0.id == request.id }
    }

    func snoozeApprovals() {
        snoozed.formUnion(approvals.map(\.id))
    }

    func jump(to request: ApprovalRequest) {
        if let agent = agent(for: request) { jump(to: agent) }
    }

    func jump(to agent: RemoteAgent) {
        if agent.desktop, let url = URL(string: agent.link) {
            NSWorkspace.shared.open(url)
        } else if agent.hosted {
            TerminalWindow.shared.show(session: agent.id)
        } else {
            Jump.to(host: agent.host, tty: agent.tty)
        }
    }

    /// Cut one agent off mid-turn — only one the notch or the daemon runs can be.
    func stop(_ agent: RemoteAgent) {
        if agent.hosted {
            fleet?.send(["type": "interrupt", "id": agent.id])
        } else {
            client?.send(["type": "interrupt", "id": agent.id])
        }
    }
    /// A typed line. Any session on the roster gets it through the agents
    /// daemon: typed into a hosted one's prompt, or over a terminal one's peer
    /// socket once it's idle. `steer` cuts a hosted one's turn short first.
    /// Only the voice agent's own session goes to the voice backend.
    func send(text: String, steer: Bool = false) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let target {
            typedTarget = target.id
            fleet?.send(["type": "type", "id": target.id, "text": text, "steer": steer])
            showTyped("sending", detail: "")
        } else if voice {
            client?.send(["type": "text", "text": text])
        }
    }

    /// The notch never activates the app, so a field in it only gets keys
    /// once its window is made key by hand.
    private func takeKeyboard() {
        NSApp?.windows.first { $0 is NotchWindow }?.makeKey()
    }

    func requestCompose() {
        takeKeyboard()
        composing = true
        composeRequest += 1
    }

    func endCompose() {
        composing = false
        composeDismiss += 1
    }

    private func showTyped(_ status: String, detail: String) {
        let name = targetName
        switch status {
        case "sending": typedStatus = "→ \(name)"
        case "sent": typedStatus = "sent to \(name)"
        case "steered": typedStatus = "steered \(name)"
        case "queued": typedStatus = "\(name) is busy — it gets this when it's free"
        case "waiting": typedStatus = "\(name) is waiting on a permission question — answer that first"
        case "gone": typedStatus = "\(name) isn't running any more"
        default: typedStatus = detail.isEmpty ? "couldn't reach \(name)" : "couldn't reach \(name): \(detail)"
        }
        typedTimer?.cancel()
        guard status != "sending" else { return }
        typedTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.typedStatus = ""
        }
    }
}
