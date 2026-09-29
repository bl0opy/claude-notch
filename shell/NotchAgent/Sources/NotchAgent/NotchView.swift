import SwiftUI

/// The three shapes the notch takes, Dynamic Island style.
enum IslandMode: Equatable {
    /// Folded into the hardware notch — nothing going on.
    case dormant
    /// A live-activity pill: status on the left, Claw'd on the right.
    case compact
    /// The pill with a line from the supervisor under it, for a few seconds.
    case notice
    /// The full panel.
    case expanded
}

struct NotchView: View {
    @ObservedObject var state: AgentState
    let geometry: NotchGeometry
    var onIslandFrame: (CGRect) -> Void = { _ in }

    private var mode: IslandMode {
        if state.expanded { return .expanded }
        if state.notice != nil { return .notice }
        return state.dormant ? .dormant : .compact
    }

    private var stripHeight: CGFloat { max(geometry.notchHeight, 26) }

    private var width: CGFloat {
        switch mode {
        case .dormant: return geometry.notchWidth
        case .compact: return geometry.notchWidth + (state.approvals.isEmpty ? 112 : 128)
        case .notice: return 400
        case .expanded: return 480
        }
    }

    private var shape: IslandShape {
        switch mode {
        case .dormant: return IslandShape(shoulder: 6, radius: 10)
        case .compact: return IslandShape(shoulder: 8, radius: 14)
        case .notice: return IslandShape(shoulder: 10, radius: 20)
        case .expanded: return IslandShape(shoulder: 12, radius: 28)
        }
    }

    /// Opening overshoots a touch, like the island does; closing doesn't.
    private var morph: Animation {
        mode == .expanded
            ? .spring(response: 0.42, dampingFraction: 0.74)
            : .spring(response: 0.36, dampingFraction: 0.9)
    }

    var body: some View {
        island
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onPreferenceChange(IslandFrameKey.self) { frame in onIslandFrame(frame) }
    }

    private var island: some View {
        VStack(spacing: 0) {
            strip
            if mode == .expanded {
                expanded
                    .transition(.island)
            } else if mode == .notice, let notice = state.notice {
                NoticeLine(notice: notice)
                    .transition(.island)
                    .contentShape(Rectangle())
                    .onTapGesture { state.open(notice) }
            }
        }
        .frame(width: width, alignment: .top)
        .background(shape.fill(.black))
        .clipShape(shape)
        .contentShape(shape)
        // A nudge when a new question lands, so the eye goes there.
        .phaseAnimator([1.0, 1.05, 1.0], trigger: state.approvals.count) { view, scale in
            view.scaleEffect(scale, anchor: .top)
        } animation: { _ in .spring(response: 0.22, dampingFraction: 0.55) }
        // Where the island is, for MouseTracker: hover and click-through
        // are decided from the cursor, not by SwiftUI.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: IslandFrameKey.self, value: proxy.frame(in: .global))
            }
        )
        .animation(morph, value: mode)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: state.approvals.isEmpty)
        .animation(.easeOut(duration: 0.18), value: state.phase)
        .animation(.easeOut(duration: 0.12), value: state.micOpen)
        .animation(.easeOut(duration: 0.18), value: state.approvals)
    }

    /// The row that sits beside the hardware notch in every mode but dormant.
    private var strip: some View {
        HStack(spacing: 0) {
            if mode != .dormant {
                HStack(spacing: 6) {
                    StatusDot(phase: state.phase, live: state.micOpen)
                    if !state.approvals.isEmpty {
                        PendingBadge(count: state.approvals.count)
                            .onTapGesture { state.snoozed = [] }
                    } else if !state.agents.isEmpty {
                        RosterBadge(agents: state.agents)
                            .onTapGesture { state.show(.agents) }
                    }
                }
                .padding(.leading, 14)
                .transition(.island)
            }
            Spacer(minLength: geometry.notchWidth)
            if mode != .dormant {
                ClaudeMark(mood: state.mood, paused: state.dormant)
                    .frame(width: 40, alignment: .trailing)
                    .padding(.trailing, 14)
                    .transition(.island)
            }
        }
        .frame(height: stripHeight)
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !state.approvals.isEmpty {
                ApprovalStack(state: state)
            }
            if state.panel == .agents {
                dashboard
            } else {
                focus
            }
            if !state.lastError.isEmpty {
                Text(state.lastError)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(AgentPhase.error.tint)
                    .lineLimit(2)
            }
            footer
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .frame(width: 480, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Two modes, not one stacked view: the agent you're talking to, or all of them.
    private var header: some View {
        HStack(spacing: 8) {
            Tab(title: "focus", on: state.panel == .focus) { state.panel = .focus }
            Tab(
                title: state.agents.isEmpty ? "agents" : "agents \(state.agents.count)",
                on: state.panel == .agents
            ) { state.panel = .agents }
            Spacer()
        }
    }

    /// The focused agent: what you said, what it said, what it's doing.
    private var focus: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !state.userTranscript.isEmpty {
                FieldBlock(title: "you", text: state.userTranscript, color: Color(white: 0.85))
                    .frame(maxHeight: 54)
            }
            if !state.assistantText.isEmpty {
                FieldBlock(title: "claude", text: state.assistantText, color: Color(white: 0.72))
                    .frame(maxHeight: state.approvals.isEmpty ? 180 : 70)
            }
            if !state.tools.isEmpty || state.phase == .thinking {
                ActivityFeed(tools: state.tools, working: state.phase == .thinking)
            }
            if !state.voice, let target = state.target {
                TargetLine(agent: target)
            }
            if state.userTranscript.isEmpty, state.assistantText.isEmpty, state.tools.isEmpty {
                Text(emptyHint)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(white: 0.34))
            }
            ComposeField(state: state)
        }
    }

    private var emptyHint: String {
        if state.micOpen { return "listening…" }
        if state.voice { return "hold \(PushToTalk.key.label) and say something, or type below" }
        if state.target == nil { return "no agents yet — + agent on the agents tab starts one" }
        return "type below to message it · click a row on the agents tab to pick another"
    }

    /// Every claude session on the machine, and the button that adds one.
    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.agents.isEmpty {
                EmptyRoster(connected: state.rosterConnected, cwd: state.sessionCwd)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(state.agents) { agent in
                            AgentRow(
                                agent: agent,
                                focused: agent.id == state.focused,
                                owned: agent.owned || state.ownedIds.contains(agent.id),
                                focus: {
                                    state.focus(agent.id)
                                    state.panel = .focus
                                },
                                jump: { state.jump(to: agent) },
                                stop: { state.stop(agent) }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: state.approvals.isEmpty ? 232 : 110)
            }

            if let totals = state.fleetTotals {
                FleetLine(totals: totals)
            }

            HStack(spacing: 10) {
                Button(action: newAgent) {
                    Text("+ agent")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Color(white: 0.18)))
                        .foregroundStyle(Color(white: 0.85))
                }
                .buttonStyle(.plain)
                if state.rosterDegraded {
                    Text("partial roster")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(AgentPhase.waiting.tint.opacity(0.8))
                }
                Spacer()
                Text(state.voice ? "click a row for the mic · ↗ to its terminal" : "click a row to message it · ↗ to its terminal")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color(white: 0.34))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            // Only an agent the notch started can be cut off mid-turn; one
            // running in a terminal has to be stopped there.
            Button(action: { state.interrupt() }) {
                Text(state.canInterrupt ? "stop" : "can't stop")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(Color(white: state.canInterrupt ? 0.18 : 0.11)))
                    .foregroundStyle(Color(white: state.canInterrupt ? 0.85 : 0.4))
            }
            .buttonStyle(.plain)
            .disabled(!state.canInterrupt)
            Text(footerHint)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(state.micOpen ? AgentPhase.listening.tint : Color(white: 0.38))
            Spacer()
            if !state.sessionCwd.isEmpty {
                Text(URL(fileURLWithPath: state.sessionCwd).lastPathComponent)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color(white: 0.4))
            }
        }
    }

    private var footerHint: String {
        if state.micOpen { return "listening — one turn until you let go" }
        if state.composing { return "↩ send · ⌘↩ steer · esc done" }
        return state.voice ? "hold \(PushToTalk.key.label) to talk · ⌃⌥T to type" : "⌃⌥T to type"
    }

    private func newAgent() {
        guard let path = PathPrompt.ask() else { return }
        state.startAgent(in: path)
        state.panel = .agents
    }
}

/// A line typed to the target agent. Return sends it; ⌘Return steers a
/// hosted one, cutting its turn short first, the way talking over it does.
private struct ComposeField: View {
    @ObservedObject var state: AgentState
    @State private var text = ""
    @FocusState private var focused: Bool

    private var disabled: Bool { !state.voice && state.target == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("›")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(white: focused ? 0.8 : 0.4))
                TextField("", text: $text, prompt: Text("message \(state.targetName)").foregroundStyle(Color(white: 0.32)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(white: 0.9))
                    .focused($focused)
                    .disabled(disabled)
                    .onKeyPress(.return, phases: .down) { press in
                        submit(steer: press.modifiers.contains(.command))
                        return .handled
                    }
                    .onExitCommand { focused = false }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(white: focused ? 0.12 : 0.08))
                    .strokeBorder(Color(white: focused ? 0.26 : 0.14), lineWidth: 1)
            )
            if !state.typedStatus.isEmpty {
                Text(state.typedStatus)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color(white: 0.5))
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .onChange(of: focused) { _, value in state.composing = value }
        .onChange(of: state.composeRequest) { _, _ in focused = true }
        .animation(.easeOut(duration: 0.15), value: state.typedStatus)
    }

    private func submit(steer: Bool) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        state.send(text: text, steer: steer)
        text = ""
    }
}

/// Typing only: who the compose field is talking to, and what it's doing.
private struct TargetLine: View {
    let agent: RemoteAgent

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(agent.state.tint)
                .frame(width: 6, height: 6)
            Text(agent.title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(white: 0.88))
            Text(agent.subtitle)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(white: 0.5))
                .lineLimit(1)
        }
    }
}

private struct Tab: View {
    let title: String
    let on: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .textCase(.uppercase)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(Color(white: on ? 0.16 : 0.09)))
                .foregroundStyle(Color(white: on ? 0.88 : 0.42))
        }
        .buttonStyle(.plain)
    }
}

/// No rows is two different situations, and saying which one saves a hunt.
private struct EmptyRoster: View {
    let connected: Bool
    let cwd: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(connected ? "no claude sessions running" : "agents daemon offline")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(white: 0.7))
            Text(connected
                 ? (cwd.isEmpty ? "start one with + agent" : "start one with + agent, or talk to this one")
                 : "start it: scripts/install-agentsd.sh — it serves :8767 and :8766")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color(white: 0.36))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

/// One session: where it is, what it's doing, what it has spent, and whether
/// the notch can do anything to it beyond watch.
/// Every session at once: how many, how many tokens, what that would cost, and
/// which window is closest to compacting.
private struct FleetLine: View {
    let totals: FleetTotals

    var body: some View {
        HStack(spacing: 8) {
            cell("\(totals.sessions)", totals.sessions == 1 ? "agent" : "agents", Color(white: 0.45))
            divider
            cell(totals.tokenLabel, "tokens", Color(white: 0.45))
            divider
            cell(totals.costLabel, "at api rates", Color(white: 0.45))
            divider
            cell(
                totals.crowded > 0 ? "\(totals.crowded) near full" : totals.contextLabel,
                "context",
                totals.pressureTint
            )
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.12)))
    }

    private var divider: some View {
        Rectangle().fill(Color(white: 0.22)).frame(width: 1, height: 14)
    }

    private func cell(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint == Color(white: 0.45) ? Color(white: 0.82) : tint)
            Text(label)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(Color(white: 0.38))
        }
    }
}

private struct AgentRow: View {
    let agent: RemoteAgent
    let focused: Bool
    /// Started by the notch — from the roster, or from what the voice backend
    /// says it owns, which is the fresher of the two.
    let owned: Bool
    let focus: () -> Void
    let jump: () -> Void
    let stop: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: focus) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(agent.state.tint)
                    .frame(width: 5, height: 5)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(agent.title)
                            .foregroundStyle(Color(white: focused ? 0.95 : 0.84))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if focused {
                            Text("mic")
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(AgentPhase.listening.tint.opacity(0.22)))
                                .foregroundStyle(AgentPhase.listening.tint)
                        }
                        if !owned {
                            Text(agent.reachable ? "terminal" : "read-only")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Color(white: 0.34))
                        }
                    }
                    Text(agent.subtitle)
                        .foregroundStyle(Color(white: agent.state == .waiting ? 0.62 : 0.44))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if hovering {
                    HStack(spacing: 4) {
                        if owned && agent.state == .working {
                            RowAction(symbol: "■", help: "stop", action: stop)
                        }
                        if agent.canJump {
                            RowAction(symbol: "↗", help: "show its terminal", action: jump)
                        }
                    }
                }
                VStack(alignment: .trailing, spacing: 1) {
                    Text(compactTokens(agent.tokensOut))
                        .foregroundStyle(Color(white: 0.42))
                        .monospacedDigit()
                    if agent.subagents > 0 {
                        Text("\(agent.subagents) sub")
                            .foregroundStyle(Color(white: 0.3))
                    }
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(focused ? Color(white: 0.14) : hovering ? Color(white: 0.1) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct RowAction: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.2)))
                .foregroundStyle(Color(white: 0.85))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct IslandFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    /// Views that don't report the frame still take part with `.zero`, so
    /// those mustn't overwrite the one that does.
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

/// The supervisor's line, under the pill: which agent, then what's going on.
private struct NoticeLine: View {
    let notice: Notice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(notice.attention ? AgentPhase.waiting.tint : Color(white: 0.45))
                .frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.project.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Color(white: 0.5))
                Text(body(of: notice))
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.9))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .frame(width: 400, alignment: .leading)
    }

    /// The project is already the label, so the line drops its own "<project> …" opener.
    private func body(of notice: Notice) -> String {
        guard !notice.project.isEmpty,
              let prefix = [notice.project + ", ", notice.project + " "].first(where: notice.line.hasPrefix)
        else { return notice.line }
        let rest = String(notice.line.dropFirst(prefix.count))
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }
}

/// Collapsed, questions outrank everything: an amber count that breathes.
private struct PendingBadge: View {
    let count: Int
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(AgentPhase.waiting.tint)
                .frame(width: 5, height: 5)
                .opacity(pulse ? 0.35 : 1)
            Text("\(count)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(AgentPhase.waiting.tint)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// How many agents there are and the worst thing any of them is doing, small
/// enough to sit beside the status dot when the notch is closed.
private struct RosterBadge: View {
    let agents: [RemoteAgent]

    private var worst: RemoteAgent.State {
        agents.map(\.state).min(by: { $0.rank < $1.rank }) ?? .idle
    }

    var body: some View {
        HStack(spacing: 3) {
            Text("\(agents.count)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(white: 0.62))
            Circle()
                .fill(worst.tint)
                .frame(width: 4, height: 4)
        }
    }
}

/// Every open permission question on the machine. The oldest gets the full card
/// and the keys; the rest wait underneath as one-liners you can clear in place.
private struct ApprovalStack: View {
    @ObservedObject var state: AgentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let top = state.topApproval {
                ApprovalCard(
                    request: top,
                    waiting: state.approvals.count - 1,
                    canJump: state.agent(for: top)?.canJump ?? false,
                    answer: { approved, always in state.answer(top, approved: approved, always: always) },
                    jump: { state.jump(to: top) },
                    hide: { state.snoozeApprovals() }
                )
            }
            ForEach(state.approvals.dropFirst().prefix(3)) { request in
                ApprovalLine(
                    request: request,
                    canJump: state.agent(for: request)?.canJump ?? false,
                    answer: { state.answer(request, approved: $0) },
                    jump: { state.jump(to: request) }
                )
            }
            if state.approvals.count > 4 {
                Text("+\(state.approvals.count - 4) more")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color(white: 0.4))
                    .padding(.leading, 11)
            }
        }
    }
}

/// 8s · 3m · 2h — how long it's been sitting there.
private func age(since: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(since)))
    switch seconds {
    case ..<60: return "\(seconds)s"
    case ..<3600: return "\(seconds / 60)m"
    default: return "\(seconds / 3600)h"
    }
}

private let allowTint = Color(red: 0.36, green: 0.85, blue: 0.55)
private let riskTint = Color(red: 1.0, green: 0.42, blue: 0.38)

private struct ApprovalCard: View {
    let request: ApprovalRequest
    let waiting: Int
    let canJump: Bool
    let answer: (_ approved: Bool, _ always: Bool) -> Void
    let jump: () -> Void
    let hide: () -> Void

    private var accent: Color { request.risky ? riskTint : AgentPhase.waiting.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(request.title)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                if request.source == "terminal" {
                    Text("also in its terminal")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Color(white: 0.36))
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(age(since: request.created, now: context.date))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color(white: 0.38))
                        .monospacedDigit()
                }
                Button(action: hide) {
                    Text("hide")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color(white: 0.45))
                }
                .buttonStyle(.plain)
            }

            Text(request.detail.isEmpty ? request.summary : request.detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(white: 0.88))
                .lineLimit(3)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            HStack(spacing: 6) {
                pill("allow", tint: allowTint) { answer(true, false) }
                if request.canAlways {
                    pill("always", tint: allowTint.opacity(0.75)) { answer(true, true) }
                }
                pill("deny", tint: Color(white: 0.6)) { answer(false, false) }
                if canJump {
                    pill("↗", tint: Color(white: 0.6), action: jump)
                }
                Spacer()
                Text(hint)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(request.risky ? riskTint.opacity(0.8) : Color(white: 0.38))
                    .lineLimit(1)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(accent.opacity(0.5), lineWidth: 1)
                )
        )
    }

    private var hint: String {
        let name = request.project.isEmpty ? "it" : request.project
        let voice = request.risky ? "say \"approve \(name)\"" : "say yes · ⌃⌥Y"
        return waiting > 0 ? "\(voice) · \(waiting) more" : voice
    }

    private func pill(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(tint.opacity(0.2)))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}

/// A question behind the top one: enough to recognise it and clear it.
private struct ApprovalLine: View {
    let request: ApprovalRequest
    let canJump: Bool
    let answer: (Bool) -> Void
    let jump: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(request.risky ? riskTint : AgentPhase.waiting.tint)
                .frame(width: 5, height: 5)
            Text(request.project.isEmpty ? request.tool : request.project)
                .foregroundStyle(Color(white: 0.8))
                .lineLimit(1)
            Text(request.detail.isEmpty ? request.summary : request.detail)
                .foregroundStyle(Color(white: 0.46))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            mini("✓", tint: allowTint) { answer(true) }
            mini("✕", tint: Color(white: 0.6)) { answer(false) }
            if canJump {
                mini("↗", tint: Color(white: 0.6), action: jump)
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 11)
        .padding(.vertical, 3)
    }

    private func mini(_ symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 20, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.18)))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}

/// What Claude is doing right now, in the shape Claude Code prints it:
/// a status dot, the tool name, and the one argument that identifies the call.
private struct ActivityFeed: View {
    let tools: [ToolEvent]
    let working: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("activity")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(white: 0.38))
                .textCase(.uppercase)
                .padding(.bottom, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(tools) { tool in
                            ActivityRow(tool: tool).id(tool.id)
                        }
                        if working {
                            WorkingRow().id(Self.workingRowID)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 108)
                .onChange(of: tools.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(working ? Self.workingRowID : tools.last?.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private static let workingRowID = "__working__"
}

private struct ActivityRow: View {
    let tool: ToolEvent

    private var dotColor: Color {
        switch tool.status {
        case .running: return AgentPhase.thinking.tint
        case .done: return Color(red: 0.36, green: 0.85, blue: 0.55)
        case .failed: return AgentPhase.error.tint
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(dotColor)
                .frame(width: 5, height: 5)
                .padding(.top, 4)
            Text(tool.name).foregroundStyle(Color(white: 0.84))
                + Text(tool.detail.isEmpty ? "" : "(\(tool.detail))")
                    .foregroundStyle(Color(white: 0.46))
        }
        .font(.system(size: 10, design: .monospaced))
        .lineLimit(2)
        .truncationMode(.middle)
    }
}

/// The tail of the feed while a turn is still in flight.
private struct WorkingRow: View {
    @State private var on = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(AgentPhase.thinking.tint)
                .frame(width: 5, height: 5)
                .opacity(on ? 0.25 : 1)
            Text("working")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(white: 0.46))
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { on = true }
        }
    }
}

private struct FieldBlock: View {
    let title: String
    let text: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(white: 0.38))
                .textCase(.uppercase)
            ScrollView {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .scrollIndicators(.never)
        }
    }
}

private struct StatusDot: View {
    let phase: AgentPhase
    /// The mic is actually open — the key is down right now.
    let live: Bool
    @State private var pulse = false

    private var tint: Color { live ? AgentPhase.listening.tint : phase.tint }

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 7, height: 7)
            .scaleEffect(pulse ? 1.5 : 1.0)
            .opacity(pulse ? 0.55 : 1.0)
            .overlay(
                Circle()
                    .stroke(AgentPhase.listening.tint.opacity(live ? 0.5 : 0), lineWidth: 1)
                    .frame(width: 15, height: 15)
            )
            .onAppear { animate() }
            .onChange(of: phase) { _, _ in animate() }
            .onChange(of: live) { _, _ in animate() }
    }

    private func animate() {
        let active = live || phase == .thinking || phase == .speaking
        withAnimation(active ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default) {
            pulse = active
        }
    }
}

/// The notch, grown: square along the top edge of the screen, flaring out into
/// it with concave shoulders, and rounded along the bottom. Both radii animate,
/// so one shape morphs between the folded, compact and expanded modes.
struct IslandShape: Shape {
    /// How far the top corners flare outward, past the frame.
    var shoulder: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, radius) }
        set { (shoulder, radius) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width / 2)
        let s = shoulder
        var path = Path()
        path.move(to: CGPoint(x: rect.minX - s, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX + s, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + s),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - r, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - r),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + s))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX - s, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

/// Content arriving in the island blurs in and settles down from the top edge;
/// leaving, it blurs out fast so the shape can close around it.
private struct IslandContent: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: hidden ? 8 : 0)
            .scaleEffect(hidden ? 0.92 : 1, anchor: .top)
            .opacity(hidden ? 0 : 1)
    }
}

extension AnyTransition {
    static var island: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: IslandContent(hidden: true), identity: IslandContent(hidden: false))
                .animation(.spring(response: 0.4, dampingFraction: 0.86).delay(0.07)),
            removal: .modifier(active: IslandContent(hidden: true), identity: IslandContent(hidden: false))
                .animation(.easeIn(duration: 0.12))
        )
    }
}
