import SwiftUI

/// Claw'd, as the 12x8 pixel sprite. Rows are read straight off the artwork:
/// `#` is shell, `.` is empty, and the eyes are simply left unpainted so they
/// read as holes on whatever the strip colour happens to be.
struct CrabSprite: View {
    let tint: Color
    /// Point size of one sprite pixel.
    var cell: CGFloat = 1.5

    private static let rows = [
        "..########..",
        "..#.####.#..",
        "############",
        "############",
        "..########..",
        "..########..",
        "..#.#..#.#..",
        "..#.#..#.#..",
    ]

    static let columns = 12
    static let lines = 8

    var body: some View {
        Canvas { context, _ in
            var path = Path()
            for (y, row) in Self.rows.enumerated() {
                for (x, character) in row.enumerated() where character == "#" {
                    // Merge each run into one rect so the sprite has no seams.
                    path.addRect(CGRect(
                        x: CGFloat(x) * cell, y: CGFloat(y) * cell,
                        width: cell, height: cell
                    ))
                }
            }
            context.fill(path, with: .color(tint))
        }
        .frame(width: CGFloat(Self.columns) * cell, height: CGFloat(Self.lines) * cell)
    }
}

/// Status indicator for the collapsed notch strip. Claw'd hops while Claude is
/// thinking, sits still otherwise, and goes grey when there's nothing going on.
struct ClaudeMark: View {
    let phase: AgentPhase

    private static let clawdRed = Color(red: 0.945, green: 0.357, blue: 0.271)

    private var isThinking: Bool { phase == .thinking }

    private var tint: Color {
        switch phase {
        case .idle, .disconnected: return Color(white: 0.34)
        case .error: return AgentPhase.error.tint
        default: return Self.clawdRed
        }
    }

    var body: some View {
        CrabSprite(tint: tint, cell: 2)
            .phaseAnimator([0, 1, 2], trigger: isThinking) { view, step in
                view
                    .offset(y: isThinking ? hopOffset(step) : 0)
                    .scaleEffect(
                        x: isThinking && step == 0 ? 1.1 : 1.0,
                        y: isThinking && step == 0 ? 0.86 : 1.0,
                        anchor: .bottom
                    )
            } animation: { step in
                guard isThinking else { return .easeOut(duration: 0.18) }
                // Crouch, spring up, land.
                switch step {
                case 0: return .easeOut(duration: 0.13)
                case 1: return .spring(response: 0.24, dampingFraction: 0.5)
                default: return .easeIn(duration: 0.22)
                }
            }
            .animation(.easeOut(duration: 0.25), value: tint)
            .accessibilityLabel(phase.label)
    }

    private func hopOffset(_ step: Int) -> CGFloat {
        switch step {
        case 0: return 0.5
        case 1: return -4.0
        default: return 0
        }
    }
}
