import SwiftUI
import XCTest
@testable import NotchAgent

/// Renders the notch in each of its states to PNGs, for looking at rather than
/// asserting on. Skipped unless SNAPSHOT_DIR says where to put them:
///
///     SNAPSHOT_DIR=/tmp/notch swift test --filter SnapshotTests
@MainActor
final class SnapshotTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] else {
            throw XCTSkip("set SNAPSHOT_DIR to render the notch")
        }
        dir = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private let roster: [String: Any] = ["type": "agents", "list": [
        agentRow("orbit", state: "waiting", host: "Terminal"),
        agentRow("voice-agent", state: "working", host: "window"),
        agentRow("descant-ide", state: "working", host: "Code"),
        agentRow("bus-tracker", state: "idle", host: "window"),
    ]]

    private func render(_ name: String, _ state: AgentState) throws {
        let geometry = NotchGeometry(screen: NSScreen.screens[0], notchWidth: 185, notchHeight: 32, hasNotch: true)
        let view = NotchView(state: state, geometry: geometry)
            .frame(width: 560, height: 520, alignment: .top)
            .background(Color(white: 0.82))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
    }

    func testPill() throws {
        let (state, _, _) = makeState(["voice": false])
        state.apply(roster)
        try render("1-pill", state)
    }

    func testDoneNotice() throws {
        let (state, _, _) = makeState(["voice": false])
        state.apply(roster)
        state.apply(["type": "fleet_event", "event": "done", "sessionId": "descant-ide", "project": "descant-ide", "long": true, "seconds": 312])
        try render("2-notice-done", state)
    }

    func testStuckNotice() throws {
        let (state, _, _) = makeState(["voice": false])
        state.apply(roster)
        state.apply(["type": "fleet_event", "event": "stuck", "sessionId": "orbit", "project": "orbit",
                     "line": "orbit looks stuck: it keeps rerunning the parser tests, which fail on the same missing import."])
        try render("3-notice-stuck", state)
    }

    func testPermissionCards() throws {
        let (state, _, _) = makeState(["voice": true])
        state.apply(roster)
        var push = approvalRow("q1", session: "orbit", project: "orbit", risky: true, canAlways: false)
        push["detail"] = "git push origin main --force-with-lease"
        var edit = approvalRow("q2", session: "descant-ide", project: "descant-ide")
        edit["tool"] = "Edit"
        edit["detail"] = "src/auth/session.ts"
        edit["summary"] = "edit session.ts"
        state.apply(["type": "approvals", "list": [push, edit, approvalRow("q3", session: "bus-tracker", project: "bus-tracker")]])
        state.hovering = true
        try render("4-permission-cards", state)
    }

    func testTypingOnlyFocus() throws {
        let (state, _, _) = makeState(["voice": false])
        state.apply(roster)
        state.focused = "voice-agent"
        state.hovering = true
        state.send(text: "use the existing session store instead")
        state.apply(["type": "typed", "id": "voice-agent", "status": "queued"])
        try render("5-typing-focus", state)
    }

    func testQuestionDropsDown() throws {
        let (state, _, _) = makeState(["voice": false])
        state.apply(roster)
        var push = approvalRow("q1", session: "orbit", project: "orbit",
                               why: "The fix is committed on main. Pushing it so the TestFlight build picks it up.",
                               always: "Bash(git push origin main)")
        push["detail"] = "git push origin main"
        state.apply(["type": "approvals", "list": [push, approvalRow("q2", session: "bus-tracker", project: "bus-tracker")]])
        try render("6-question", state)
    }

    func testMarkdownFormatting() throws {
        let view = MarkdownText("""
        ## What changed
        The **notch** now reads `settings.json` and [the docs](https://example.com).

        - first thing
          - nested thing
        1. a numbered step

        > a quoted line

        ```python
        print("hello")
        ```

        | Cause | Prompts |
        |---|---|
        | Heredocs | 253 |
        """)
        .padding(16).frame(width: 480).background(.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("9-markdown.png"))
    }

    func testDesktopSessionPanel() throws {
        let (state, _, _) = makeState(["voice": false])
        state.apply(["type": "agents", "list": [
            desktopRow("presently", state: "idle", title: "TestFlight update", summary: "added the 1.5.0 notes; pushed b204d20"),
            desktopRow("voice-agent", state: "working", title: "Notch Agent"),
        ]])
        state.focus("presently")
        state.apply(["type": "chat", "id": "presently", "rows": [
            ["role": "you", "text": "add the what's new notes and push"],
            ["role": "tool", "text": "Edit(Presently/WhatsNew.swift)"],
            ["role": "tool", "text": "Bash(git push origin main)"],
            ["role": "claude", "text": "Added the 1.5.0 entry and pushed b204d20."],
        ]])
        state.hovering = true
        try render("8-desktop-panel", state)
    }

    func testVoiceFocusEmpty() throws {
        let (state, _, _) = makeState(["voice": true])
        state.apply(roster)
        state.hovering = true
        try render("7-voice-focus", state)
    }
}
