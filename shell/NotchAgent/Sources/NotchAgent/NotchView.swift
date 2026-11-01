import SwiftUI

/// The three shapes the notch takes, Dynamic Island style.
enum IslandMode: Equatable {
    /// Folded into the hardware notch — nothing going on.
    case dormant
    /// A live-activity pill: status on the left, Claw'd on the right.
    case compact
    /// The pill with a line from the supervisor under it, for a few seconds.
    case notice
    /// A permission question, dropped down on its own so it can be answered
    /// without going to find it.
    case question
    /// The full panel.
    case expanded
}

struct NotchView: View {
    @ObservedObject var state: AgentState
    let geometry: NotchGeometry
    var onIslandFrame: (CGRect) -> Void = { _ in }

    private var mode: IslandMode { state.islandMode }

    private var stripHeight: CGFloat { max(geometry.notchHeight, 26) }

    private var width: CGFloat {
        switch mode {
        case .dormant: return geometry.notchWidth
        case .compact: return geometry.notchWidth + (state.approvals.isEmpty ? 112 : 128)
        case .notice: return 400
        case .question, .expanded: return 480
        }
    }

    private var shape: IslandShape {
        switch mode {
        case .dormant: return IslandShape(shoulder: 6, radius: 10)
        case .compact: return IslandShape(shoulder: 8, radius: 14)
        case .notice: return IslandShape(shoulder: 10, radius: 20)
        case .question, .expanded: return IslandShape(shoulder: 12, radius: 28)
        }
    }

    /// Opening overshoots a touch, like the island does; closing doesn't.
    private var morph: Animation {
        mode == .expanded || mode == .question
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
            } else if mode == .question {
                ApprovalStack(state: state)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                    .frame(width: 480, alignment: .leading)
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
        .contextMenu {
            Button("Settings…") { SettingsWindow.shared.show() }
            if state.hostedAgents {
                Button("Terminal window") { TerminalWindow.shared.show() }
            }
            Divider()
            Button("Quit Notch Agent") { NSApp.terminate(nil) }
        }
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

    /// Every session along the top, the chosen one's conversation under it,
    /// and a line to answer it in.
    private var expanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            SessionChips(state: state)
            if !state.approvals.isEmpty {
                ApprovalStack(state: state)
            }
            if let target = state.target {
                TargetLine(agent: target, open: { state.jump(to: target) })
            }
            if state.voice, !state.userTranscript.isEmpty || !state.assistantText.isEmpty {
                voiceTurn
            }
            if state.target != nil {
                ChatView(rows: state.chat, loading: state.chatFor != state.target?.id,
                         maxHeight: state.approvals.isEmpty ? 250 : 110)
            } else {
                Text(emptyHint)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(white: 0.34))
            }
            if state.addingAgent {
                NewAgentField(state: state)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            ComposeField(state: state)
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

    /// What you said to the voice agent and what it said back.
    private var voiceTurn: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !state.userTranscript.isEmpty {
                FieldBlock(title: "you", text: state.userTranscript, color: Color(white: 0.85))
                    .frame(maxHeight: 54)
            }
            if !state.assistantText.isEmpty {
                FieldBlock(title: "claude", text: state.assistantText, color: Color(white: 0.72))
                    .frame(maxHeight: 90)
            }
            if !state.tools.isEmpty || state.phase == .thinking {
                ActivityFeed(tools: state.tools, working: state.phase == .thinking)
            }
        }
    }

    private var emptyHint: String {
        if state.micOpen { return "listening…" }
        if !state.rosterConnected { return "agents daemon offline — run ./run.sh" }
        if state.voice { return "hold \(PushToTalk.key.label) and say something" }
        return "no claude sessions running"
    }

    private var footer: some View {
        HStack(spacing: 10) {
            // Only an agent the notch started can be cut off mid-turn.
            if state.canInterrupt {
                Button(action: { state.interrupt() }) {
                    Text("stop")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(Color(white: 0.18)))
                        .foregroundStyle(Color(white: 0.85))
                }
                .buttonStyle(.plain)
            }
            Text(footerHint)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(state.micOpen ? AgentPhase.listening.tint : Color(white: 0.38))
            Spacer()
        }
    }

    private var footerHint: String {
        if state.micOpen { return "listening — one turn until you let go" }
        if state.addingAgent { return "↩ start · tab completes · esc cancels" }
        if state.composing { return "↩ send · esc done" }
        return state.voice ? "hold \(PushToTalk.key.label) to talk · ⌃⌥T to type" : "⌃⌥T to type · right-click for settings"
    }
}

/// Every session as a chip, worst first. The chosen one is who the chat and
/// the reply line are about; + starts a hosted agent when those are on.
private struct SessionChips: View {
    @ObservedObject var state: AgentState

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(state.agents) { agent in
                    chip(agent)
                }
                if state.hostedAgents {
                    Button(action: toggleNewAgent) {
                        Text(state.addingAgent ? "×" : "+")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .frame(width: 22, height: 20)
                            .background(Capsule().fill(Color(white: 0.14)))
                            .foregroundStyle(Color(white: 0.7))
                    }
                    .buttonStyle(.plain)
                    .help(state.addingAgent ? "cancel" : "start an agent")
                }
            }
        }
        .scrollIndicators(.never)
    }

    private func chip(_ agent: RemoteAgent) -> some View {
        let on = agent.id == state.target?.id
        return Button(action: { state.focus(agent.id) }) {
            HStack(spacing: 5) {
                Circle()
                    .fill(agent.state.tint)
                    .frame(width: 5, height: 5)
                Text(agent.label)
                    .lineLimit(1)
                    .frame(maxWidth: 150)
                    .fixedSize()
            }
            .font(.system(size: 10, weight: on ? .semibold : .regular, design: .monospaced))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(Color(white: on ? 0.17 : 0.09)))
            .foregroundStyle(Color(white: on ? 0.92 : 0.55))
        }
        .buttonStyle(.plain)
        .help(agent.title)
    }

    private func toggleNewAgent() {
        if state.addingAgent {
            state.cancelNewAgent()
        } else {
            state.requestNewAgent()
        }
    }
}

/// The conversation so far: what you said, what Claude said, one dim line per
/// tool call. Kept scrolled to the latest.
private struct ChatView: View {
    let rows: [ChatRow]
    let loading: Bool
    let maxHeight: CGFloat

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    if rows.isEmpty {
                        Text(loading ? "loading…" : "nothing said yet")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color(white: 0.34))
                    }
                    ForEach(rows) { row in
                        ChatLine(row: row).id(row.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: maxHeight)
            .onAppear { proxy.scrollTo(rows.last?.id, anchor: .bottom) }
            .onChange(of: rows) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(rows.last?.id, anchor: .bottom) }
            }
        }
    }
}

private struct ChatLine: View {
    let row: ChatRow

    var body: some View {
        switch row.role {
        case .tool:
            HStack(alignment: .top, spacing: 7) {
                Circle()
                    .fill(Color(white: 0.3))
                    .frame(width: 4, height: 4)
                    .padding(.top, 5)
                Text(row.text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(white: 0.42))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .you, .notch:
            HStack(alignment: .top, spacing: 7) {
                Text(row.role == .you ? "›" : "◦")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(white: 0.5))
                Text(row.text)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.92))
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
            .padding(.top, 4)
            .help(row.role == .notch ? "sent from the notch" : "")
        case .claude:
            Text(row.text)
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.74))
                .lineLimit(12)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// "+ agent", inline: a path with the folders that finish it underneath.
/// Return starts it, tab takes the first suggestion, esc closes it.
private struct NewAgentField: View {
    @ObservedObject var state: AgentState
    @State private var text = AgentPath.initial
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var suggestions: [String] { AgentPath.suggestions(for: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("+")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(white: 0.7))
                TextField("", text: $text, prompt: Text("a folder for the new agent").foregroundStyle(Color(white: 0.32)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(white: 0.9))
                    .focused($focused)
                    .onSubmit(submit)
                    .onExitCommand { state.cancelNewAgent() }
                    .onKeyPress(.tab) {
                        guard let first = suggestions.first else { return .ignored }
                        text = first
                        return .handled
                    }
                    .onChange(of: text) { _, _ in problem = nil }
                Button("start", action: submit)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(white: 0.85))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(white: 0.12))
                    .strokeBorder(Color(white: problem == nil ? 0.26 : 0.4), lineWidth: 1)
            )

            if let problem {
                Text(problem)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(AgentPhase.error.tint)
                    .lineLimit(1)
                    .truncationMode(.head)
            } else if !suggestions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Text((suggestion as NSString).lastPathComponent)
                            .font(.system(size: 9, design: .monospaced))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color(white: 0.14)))
                            .foregroundStyle(Color(white: 0.7))
                            .lineLimit(1)
                            .onTapGesture {
                                text = suggestion
                                focused = true
                            }
                    }
                }
            }
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: state.newAgentRequest) { _, _ in DispatchQueue.main.async { focused = true } }
        .onChange(of: state.composeDismiss) { _, _ in focused = false }
        .onChange(of: focused) { _, value in state.composing = value }
        .onDisappear { state.composing = false }
    }

    private func submit() {
        problem = state.submitNewAgent(text)
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
                TextField("", text: $text, prompt: Text("reply to \(state.targetName)").foregroundStyle(Color(white: 0.32)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(white: 0.9))
                    .focused($focused)
                    .disabled(disabled)
                    // The field editor takes Return for itself, so ⌘ is read
                    // off the keyboard as it's submitted.
                    .onSubmit { submit(steer: NSEvent.modifierFlags.contains(.command)) }
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
        .onChange(of: state.composeRequest) { _, _ in take() }
        .onChange(of: state.composeDismiss) { _, _ in focused = false }
        // ⌃⌥T on a folded notch opens the panel first; the field it asked
        // for only exists once it's open.
        .onAppear { if state.composing { take() } }
        .animation(.easeOut(duration: 0.15), value: state.typedStatus)
    }

    private func take() {
        DispatchQueue.main.async { focused = true }
    }

    private func submit(steer: Bool) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        state.send(text: text, steer: steer)
        text = ""
    }
}

/// Typing only: who the compose field is talking to, and what it's doing.
/// The chosen session: where it is, what it's doing, and a way into it.
private struct TargetLine: View {
    let agent: RemoteAgent
    let open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(agent.title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(white: 0.6))
                .lineLimit(1)
                .fixedSize()
            Text(agent.subtitle)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(white: agent.state == .waiting ? 0.7 : 0.42))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if agent.canJump {
                Button(action: open) {
                    Text(agent.desktop ? "open in app ↗" : "↗")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color(white: 0.5))
                }
                .buttonStyle(.plain)
            }
        }
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
                .fill(notice.attention ? AgentPhase.waiting.tint
                      : notice.kind == .done ? Color(red: 0.36, green: 0.85, blue: 0.55)
                      : Color(white: 0.45))
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
                    ask: { state.ask(top) },
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
    let ask: () -> Void
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
                    Text("also asked in its session")
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

            if !request.why.isEmpty {
                Text(request.why)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.62))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                pill("allow", tint: allowTint) { answer(true, false) }
                if request.canAlways {
                    pill("always", tint: allowTint.opacity(0.75)) { answer(true, true) }
                        .help(request.always.isEmpty ? "allow this from now on" : "adds \(request.always)")
                }
                pill("deny", tint: Color(white: 0.6)) { answer(false, false) }
                pill("why?", tint: Color(white: 0.6), action: ask)
                    .help("it explains itself and asks again")
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
        let keys = request.always.isEmpty ? "⌃⌥Y · ⌃⌥N" : "always: \(request.always)"
        return waiting > 0 ? "\(keys) · \(waiting) more" : keys
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
