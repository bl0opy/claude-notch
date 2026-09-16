import SwiftUI

struct NotchView: View {
    @ObservedObject var state: AgentState
    let geometry: NotchGeometry

    private var collapsedWidth: CGFloat { geometry.notchWidth + 112 }

    var body: some View {
        VStack(spacing: 0) {
            collapsed
            if state.expanded {
                expanded
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: state.expanded)
        .animation(.easeOut(duration: 0.18), value: state.phase)
        .animation(.easeOut(duration: 0.12), value: state.micOpen)
        .animation(.easeOut(duration: 0.18), value: state.approvals)
        .onHover { hovering in
            state.hovering = hovering
        }
    }

    private var collapsed: some View {
        HStack(spacing: 0) {
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
            .frame(width: 56, alignment: .leading)
            .padding(.leading, 14)
            Spacer(minLength: geometry.notchWidth)
            ClaudeMark(phase: state.phase)
                .frame(width: 40, alignment: .trailing)
                .padding(.trailing, 14)
        }
        .frame(width: collapsedWidth, height: max(geometry.notchHeight, 26))
        .background(
            NotchShape(cornerRadius: 12)
                .fill(.black)
        )
        // Click the notch to pin the panel open — hovering is fine for a glance,
        // useless for reading a dashboard while you work somewhere else.
        .onTapGesture { state.pinned.toggle() }
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
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 460, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(white: 0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color(white: 0.18), lineWidth: 1)
                )
        )
        .padding(.top, 6)
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
            if state.pinned {
                Button(action: { state.pinned = false }) {
                    Text("unpin")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color(white: 0.45))
                }
                .buttonStyle(.plain)
            }
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
            if state.userTranscript.isEmpty, state.assistantText.isEmpty, state.tools.isEmpty {
                Text(state.micOpen ? "listening…" : "hold \(PushToTalk.key.label) and say something")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(white: 0.34))
            }
        }
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
                Text("click a row for the mic · ↗ to its terminal")
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
            Text(state.micOpen
                 ? "listening — one turn until you let go"
                 : "hold \(PushToTalk.key.label) to talk")
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

    private func newAgent() {
        guard let path = ProjectPicker.chooseDirectory(startingAt: state.sessionCwd) else { return }
        state.startAgent(in: path)
        state.panel = .agents
        state.pinned = true
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

/// The rounded-underside shape that makes the panel read as an extension of the notch.
struct NotchShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
