import SwiftUI

/// Claw'd, as the 12x8 pixel sprite. The body is fixed artwork; the eyes and
/// legs are drawn per frame so he can blink, glance and shuffle. Eyes are left
/// unpainted, so they read as holes on whatever the strip colour is.
struct CrabSprite: View {
    enum Eyes: Equatable {
        /// Holes where the eyes are, shifted a column to glance left (-1) or right (1).
        case open(look: Int)
        case closed
    }

    let tint: Color
    /// Point size of one sprite pixel.
    var cell: CGFloat = 1.5
    var eyes: Eyes = .open(look: 0)
    /// 0 planted, 1 mid-step.
    var legs: Int = 0

    private static let body = [
        "..########..",
        "..########..",
        "############",
        "############",
        "..########..",
        "..########..",
    ]
    private static let legFrames = [
        ["..#.#..#.#..", "..#.#..#.#.."],
        ["..#.#..#.#..", ".#..#..#..#."],
    ]

    static let columns = 12
    static let lines = 8

    private var rows: [String] {
        var rows = Self.body
        if case .open(let look) = eyes {
            var eyeRow = Array(rows[1])
            eyeRow[3 + look] = "."
            eyeRow[8 + look] = "."
            rows[1] = String(eyeRow)
        }
        return rows + Self.legFrames[legs % Self.legFrames.count]
    }

    var body: some View {
        Canvas { context, _ in
            var path = Path()
            for (y, row) in rows.enumerated() {
                for (x, character) in row.enumerated() where character == "#" {
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

/// What Claw'd is up to, which is how the notch looks at a glance.
enum CrabMood: Equatable {
    /// Nothing running anywhere: grey, eyes shut, the odd z.
    case asleep
    /// Around, not busy: blinks, glances about, shuffles now and then.
    case idle
    /// Someone's parked on a permission question: paces side to side.
    case waiting
    /// The mic is open: stands up straight, eyes forward, still.
    case listening
    /// Claude is working: hops.
    case thinking
    /// Reading an answer out: a quick bob.
    case speaking
    case error
}

/// Status indicator for the collapsed notch strip.
///
/// Everything but the hop is frame-based at 12 fps, the way a sprite would be
/// animated, and derived from the clock rather than timers — so it costs nothing
/// to stop, and pauses outright while the notch is folded away.
struct ClaudeMark: View {
    let mood: CrabMood
    var paused: Bool = false

    private static let clawdRed = Color(red: 0.945, green: 0.357, blue: 0.271)

    private var tint: Color {
        switch mood {
        case .asleep: return Color(white: 0.34)
        case .error: return AgentPhase.error.tint
        default: return Self.clawdRed
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: paused || mood == .thinking)) { context in
            let frame = Frame(mood: mood, time: context.date.timeIntervalSinceReferenceDate)
            ZStack(alignment: .topTrailing) {
                CrabSprite(tint: tint, cell: 2, eyes: frame.eyes, legs: frame.legs)
                    .offset(x: frame.dx, y: frame.dy)
                    .modifier(Hop(active: mood == .thinking))
                if let z = frame.z {
                    Text("z")
                        .font(.system(size: 7 + 2 * z, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(white: 0.5).opacity(1 - z))
                        .offset(x: 6 + 4 * z, y: -2 - 9 * z)
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: tint)
        .accessibilityLabel(String(describing: mood))
    }
}

/// One sprite frame, worked out from the mood and the time.
private struct Frame {
    var eyes: CrabSprite.Eyes = .open(look: 0)
    var legs = 0
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    /// 0...1 through a rising z, or nil when there isn't one.
    var z: Double?

    init(mood: CrabMood, time t: Double) {
        switch mood {
        case .asleep:
            eyes = .closed
            // Slow breath, and a z drifting up every few seconds.
            dy = sin(t * .pi / 1.6) > 0.6 ? -0.5 : 0
            let cycle = t.truncatingRemainder(dividingBy: 3.2) / 3.2
            z = cycle < 0.75 ? cycle / 0.75 : nil

        case .idle:
            eyes = .open(look: Self.glance(t))
            if Self.blinking(t) { eyes = .closed }
            // A little shuffle every ~7 s: two quick steps to one side and back.
            let shuffle = t.truncatingRemainder(dividingBy: 7.3)
            if shuffle < 0.66 {
                let step = Int(shuffle / 0.165)
                legs = step % 2
                dx = [0, 1, 1, 0][min(step, 3)] * 2
            }

        case .waiting:
            // Pace: step, step, look up at you, step back.
            let beat = Int((t * 5).rounded(.down)) % 8
            legs = beat % 2
            dx = [0, 1, 2, 2, 2, 1, 0, 0][beat] * 2 - 2
            eyes = beat == 3 || beat == 7 ? .open(look: 0) : .open(look: beat < 4 ? 1 : -1)
            if Self.blinking(t) { eyes = .closed }

        case .listening:
            dy = -1
            if Self.blinking(t * 0.6) { eyes = .closed }

        case .speaking:
            dy = Int((t * 8).rounded(.down)) % 2 == 0 ? 0 : -1
            if Self.blinking(t) { eyes = .closed }

        case .thinking, .error:
            break
        }
    }

    /// Short blinks on an uneven rhythm, with the occasional double.
    private static func blinking(_ t: Double) -> Bool {
        let a = t.truncatingRemainder(dividingBy: 4.1)
        let b = t.truncatingRemainder(dividingBy: 11.3)
        return a < 0.12 || (b > 0.3 && b < 0.42)
    }

    /// Looks left for a moment, back, right, back — every ~9 s.
    private static func glance(_ t: Double) -> Int {
        let g = t.truncatingRemainder(dividingBy: 9.7)
        if g > 5.0 && g < 6.1 { return -1 }
        if g > 7.4 && g < 8.3 { return 1 }
        return 0
    }
}

/// Crouch, spring up, land — on repeat while Claude is thinking.
private struct Hop: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        // No `trigger:` — that variant runs once per change. The plain one cycles
        // forever, and the offsets flatten to zero when he's not hopping.
        content.phaseAnimator([0, 1, 2]) { view, step in
            view
                .offset(y: active ? [0.5, -4.0, 0][step] : 0)
                .scaleEffect(
                    x: active && step == 0 ? 1.1 : 1.0,
                    y: active && step == 0 ? 0.86 : 1.0,
                    anchor: .bottom
                )
        } animation: { step in
            guard active else { return .linear(duration: 0.5) }
            switch step {
            case 0: return .easeOut(duration: 0.13)
            case 1: return .spring(response: 0.24, dampingFraction: 0.5)
            default: return .easeIn(duration: 0.22)
            }
        }
    }
}
