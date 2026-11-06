import AppKit

/// Decides, from the cursor alone, whether the notch is being hovered and
/// whether its window should take clicks at all.
///
/// The window is a fixed 720×600 panel at the top of the screen, big enough for
/// the open panel, and most of it is empty. Left to itself it sits over whatever
/// is under it, so a click or drag up there could land in the notch instead:
/// dragging a window across the top of the screen opened the panel under the
/// cursor and the panel took the drag. So:
///
/// - the window ignores the mouse unless the cursor is on the island itself;
/// - hovering only starts with no button held — passing over with a drag in
///   progress never opens it;
/// - leaving closes after a beat, so skimming past the edge doesn't slam it.
///
/// Global mouse-moved events don't reliably arrive while the cursor is over
/// the menu bar, which is exactly where the notch is, so the cursor is also
/// polled.
@MainActor
final class MouseTracker {
    private weak var window: NSWindow?
    private let state: AgentState
    private var monitors: [Any] = []
    private var poll: Timer?
    private var leaving: DispatchWorkItem?
    /// The island's frame in the window's SwiftUI space (top-left origin).
    var island: CGRect = .zero {
        didSet { update() }
    }

    init(state: AgentState) {
        self.state = state
    }

    func install(on window: NSWindow) {
        self.window = window
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseUp, .rightMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor in self?.update() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            Task { @MainActor in self?.update() }
            return event
        }) {
            monitors.append(local)
        }
        poll = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        update()
    }

    func uninstall() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        poll?.invalidate()
        poll = nil
    }

    private func islandOnScreen(in window: NSWindow) -> CGRect {
        let frame = window.frame
        return CGRect(
            x: frame.minX + island.minX,
            y: frame.maxY - island.maxY,
            width: island.width,
            height: island.height
        )
    }

    private func update() {
        guard let window else { return }
        guard window.isVisible else {
            window.ignoresMouseEvents = true
            return
        }
        let cursor = NSEvent.mouseLocation
        // The screen's top edge counts as inside: the cursor pinned against it
        // above the notch is aiming for the notch. Folded, the island is only
        // the hardware notch, so give it some slack either side.
        let slack: CGFloat = state.islandMode == .dormant ? -24 : 0
        let target = islandOnScreen(in: window).insetBy(dx: slack, dy: -2)
        let inside = !island.isEmpty && target.contains(cursor)
        window.ignoresMouseEvents = !inside

        if inside {
            leaving?.cancel()
            leaving = nil
            let dragging = NSEvent.pressedMouseButtons != 0
            if !state.hovering && !dragging { state.hovering = true }
        } else if state.hovering && leaving == nil {
            let close = DispatchWorkItem { [weak self] in
                self?.leaving = nil
                self?.state.hovering = false
            }
            leaving = close
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: close)
        }
    }
}
