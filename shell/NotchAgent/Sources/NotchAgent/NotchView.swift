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
        .onHover { hovering in
            state.expanded = hovering
        }
    }

    private var collapsed: some View {
        HStack(spacing: 0) {
            StatusDot(phase: state.phase)
                .frame(width: 40, alignment: .leading)
                .padding(.leading, 14)
            Spacer(minLength: geometry.notchWidth)
            Text(state.phase.label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(white: 0.62))
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
            }
            if !state.assistantText.isEmpty {
                FieldBlock(title: "claude", text: state.assistantText, color: Color(white: 0.72))
                    .frame(maxHeight: 180)
            }
            if !state.tools.isEmpty {
                HStack(spacing: 6) {
                    ForEach(state.tools) { tool in
                        Text(tool.name.lowercased())
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color(white: 0.16)))
                            .foregroundStyle(Color(white: 0.66))
                    }
                }
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
                Spacer()
                if !state.sessionCwd.isEmpty {
                    Text(URL(fileURLWithPath: state.sessionCwd).lastPathComponent)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color(white: 0.4))
                }
            }
        }
        .padding(16)
        .frame(width: 460, alignment: .leading)
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
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(phase.tint)
            .frame(width: 7, height: 7)
            .scaleEffect(pulse ? 1.5 : 1.0)
            .opacity(pulse ? 0.55 : 1.0)
            .onAppear { animate() }
            .onChange(of: phase) { _, _ in animate() }
    }

    private func animate() {
        let active = phase == .listening || phase == .thinking || phase == .speaking
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
