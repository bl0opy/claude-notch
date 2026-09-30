import XCTest
@testable import NotchAgent

/// The notch's news: a turn ending, a progress line, a stuck agent.
@MainActor
final class NoticeTests: XCTestCase {
    private func done(_ id: String, long: Bool = true, seconds: Int = 240) -> [String: Any] {
        ["type": "fleet_event", "event": "done", "sessionId": id, "project": id, "long": long, "seconds": seconds]
    }

    private func line(_ event: String, _ id: String, _ text: String) -> [String: Any] {
        ["type": "fleet_event", "event": event, "sessionId": id, "project": id, "line": text]
    }

    func testALongTurnEndingShowsAndChimesTypingOnly() {
        let (state, _, _) = makeState(["voice": false])
        var chimes: [AgentState.Chime] = []
        state.play = { chimes.append($0) }
        state.apply(done("orbit"))
        XCTAssertEqual(state.notice?.kind, .done)
        XCTAssertEqual(state.notice?.line, "orbit done after 4 minutes")
        XCTAssertEqual(state.islandMode, .notice)
        XCTAssertEqual(chimes, [.done])
    }

    func testAShortTurnEndingIsQuiet() {
        let (state, _, _) = makeState(["voice": false])
        state.apply(done("orbit", long: false, seconds: 5))
        XCTAssertNil(state.notice)
    }

    func testWithVoiceTheAgentYouTalkToIsHeardNotShown() {
        let (state, _, _) = makeState(["voice": true])
        state.focused = "orbit"
        state.apply(done("orbit"))
        XCTAssertNil(state.notice)
        state.apply(done("descant"))
        XCTAssertEqual(state.notice?.sessionId, "descant")
    }

    func testTypingOnlyEvenTheAgentYouTypeToShows() {
        let (state, _, _) = makeState(["voice": false])
        state.focused = "orbit"
        state.apply(done("orbit"))
        XCTAssertEqual(state.notice?.sessionId, "orbit")
    }

    func testNothingCoversAStuckAgent() {
        let (state, _, _) = makeState(["voice": false])
        state.apply(line("stuck", "orbit", "orbit looks stuck: it keeps running the tests."))
        state.apply(line("progress", "descant", "descant, 4 minutes in."))
        XCTAssertEqual(state.notice?.kind, .stuck)
        state.apply(done("bus"))
        XCTAssertEqual(state.notice?.kind, .stuck)
        state.apply(line("stuck", "bus", "bus looks stuck: it hasn't done anything for 6 minutes."))
        XCTAssertEqual(state.notice?.sessionId, "bus", "a newer stuck one does")
    }

    func testAStuckAgentReplacesProgressAndProgressIsSilent() {
        let (state, _, _) = makeState(["voice": false])
        var chimes: [AgentState.Chime] = []
        state.play = { chimes.append($0) }
        state.apply(line("progress", "descant", "descant, 4 minutes in."))
        XCTAssertEqual(chimes, [])
        state.apply(line("stuck", "orbit", "orbit looks stuck: it keeps failing."))
        XCTAssertEqual(state.notice?.kind, .stuck)
        XCTAssertEqual(chimes, [.attention])
    }

    func testDoneLines() {
        XCTAssertEqual(Notice.doneLine(project: "orbit", seconds: 45), "orbit done after 45 seconds")
        XCTAssertEqual(Notice.doneLine(project: "orbit", seconds: 60), "orbit done after 1 minute")
        XCTAssertEqual(Notice.doneLine(project: "", seconds: 600), "An agent done after 10 minutes")
    }

    func testDismissing() {
        let (state, _, _) = makeState(["voice": false])
        state.apply(done("orbit"))
        state.dismissNotice()
        XCTAssertNil(state.notice)
        XCTAssertNotEqual(state.islandMode, .notice)
    }
}

/// How the island opens, shrinks and folds away.
@MainActor
final class IslandModeTests: XCTestCase {
    func testQuietWithAgentsIsThePill() {
        let (state, _, _) = makeState(["notch_fold_after": 300])
        state.apply(["type": "agents", "list": [agentRow("a")]])
        XCTAssertEqual(state.islandMode, .compact)
    }

    func testHoverComposeAndTalkOpenThePanel() {
        let (state, _, _) = makeState(["voice": true])
        state.hovering = true
        XCTAssertEqual(state.islandMode, .expanded)
        state.hovering = false
        state.composing = true
        XCTAssertEqual(state.islandMode, .expanded, "typing keeps it open with the cursor elsewhere")
        state.composing = false
        state.micOpen = true
        XCTAssertEqual(state.islandMode, .expanded)
    }

    func testItFoldsAfterTheQuietAndCameBackWhenSomethingStarts() {
        let (state, _, _) = makeState(["notch_fold_after": 0.05])
        state.apply(["type": "agents", "list": [agentRow("a", state: "idle")]])
        Thread.sleep(forTimeInterval: 0.1)
        state.settle()
        XCTAssertEqual(state.islandMode, .dormant)
        state.apply(["type": "agents", "list": [agentRow("a", state: "working")]])
        XCTAssertEqual(state.islandMode, .compact)
    }

    func testAQuestionKeepsItFromFolding() {
        let (state, _, _) = makeState(["notch_fold_after": 0.05])
        state.apply(["type": "approvals", "list": [approvalRow("q1")]])
        Thread.sleep(forTimeInterval: 0.1)
        state.settle()
        XCTAssertNotEqual(state.islandMode, .dormant)
    }

    func testZeroNeverFolds() {
        let (state, _, _) = makeState(["notch_fold_after": 0])
        Thread.sleep(forTimeInterval: 0.05)
        state.settle()
        XCTAssertEqual(state.islandMode, .compact)
    }

    func testHoveringAFoldedNotchOpensIt() {
        let (state, _, _) = makeState(["notch_fold_after": 0.05])
        Thread.sleep(forTimeInterval: 0.1)
        state.settle()
        XCTAssertEqual(state.islandMode, .dormant)
        state.hovering = true
        XCTAssertEqual(state.islandMode, .expanded)
    }

    func testTypingOnlyStartsIdleNotOffline() {
        let (typing, _, _) = makeState(["voice": false])
        XCTAssertEqual(typing.phase, .idle)
        let (voice, _, _) = makeState(["voice": true])
        XCTAssertEqual(voice.phase, .disconnected)
    }
}
