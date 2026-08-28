import SwiftUI

struct NotchView: View {
    @ObservedObject var state: AgentState
    let geometry: NotchGeometry

    private var collapsedWidth: CGFloat { geometry.notchWidth + 96 }

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
        .onHover { hovering in
            state.hovering = hovering
        }
    }

    private var collapsed: some View {
        HStack(spacing: 0) {
            StatusDot(phase: state.phase, live: state.micOpen)
                .frame(width: 40, alignment: .leading)
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
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !state.userTranscript.isEmpty {
                FieldBlock(title: "you", text: state.userTranscript, color: Color(white: 0.85))
                    .frame(maxHeight: 54)
            }
            if !state.assistantText.isEmpty {
                FieldBlock(title: "claude", text: state.assistantText, color: Color(white: 0.72))
                    .frame(maxHeight: 180)
            }
            if let request = state.approval {
                ApprovalCard(request: request) { state.answerApproval($0) }
            }
            if !state.tools.isEmpty || state.phase == .thinking {
                ActivityFeed(tools: state.tools, working: state.phase == .thinking)
            }
            if !state.lastError.isEmpty {
                Text(state.lastError)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(AgentPhase.error.tint)
                    .lineLimit(2)
            }
            HStack(spacing: 10) {
                Button(action: { state.interrupt() }) {
                    Text("stop")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(Color(white: 0.18)))
                        .foregroundStyle(Color(white: 0.85))
                }
                .buttonStyle(.plain)
                Text(state.micOpen ? "listening — let go when done" : "hold ⌘ to talk")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(state.micOpen ? AgentPhase.listening.tint : Color(white: 0.38))
                Spacer()
                if !state.sessionCwd.isEmpty {
                    Text(URL(fileURLWithPath: state.sessionCwd).lastPathComponent)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color(white: 0.4))
                }
            }
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
}

/// The permission question, with the two buttons. Saying "yeah" or "nope" does
/// the same thing — this is here for when talking isn't convenient.
private struct ApprovalCard: View {
    let request: ApprovalRequest
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("needs your ok")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(AgentPhase.waiting.tint)
                .textCase(.uppercase)

            Text(request.reason.isEmpty ? request.tool : request.reason)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(white: 0.86))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                answerButton("approve", tint: Color(red: 0.36, green: 0.85, blue: 0.55)) { answer(true) }
                answerButton("deny", tint: Color(white: 0.55)) { answer(false) }
                Spacer()
                Text("or just say yeah / nope")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color(white: 0.38))
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AgentPhase.waiting.tint.opacity(0.45), lineWidth: 1)
                )
        )
    }

    private func answerButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(tint.opacity(0.22)))
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
