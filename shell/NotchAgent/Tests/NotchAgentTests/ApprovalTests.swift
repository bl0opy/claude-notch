import XCTest
@testable import NotchAgent

/// Permission cards: what shows, what answering sends, what makes a sound.
@MainActor
final class ApprovalTests: XCTestCase {
    func testCardsArriveInOrderAndTheOldestIsTheOneKeysAnswer() {
        let (state, _, _) = makeState(["voice": false])
        state.apply(["type": "approvals", "list": [approvalRow("q1"), approvalRow("q2", project: "descant")]])
        XCTAssertEqual(state.approvals.map(\.id), ["q1", "q2"])
        XCTAssertEqual(state.topApproval?.id, "q1")
        XCTAssertEqual(state.approvals[1].title, "descant · Bash")
    }

    func testAnsweringGoesToTheDaemonAndTakesTheCardDownAtOnce() {
        let (state, client, fleet) = makeState(["voice": true])
        state.apply(["type": "approvals", "list": [approvalRow("q1"), approvalRow("q2")]])
        state.answer(state.approvals[0], approved: true, always: true)
        XCTAssertEqual(fleet.types, ["approve"])
        XCTAssertEqual(fleet.sent[0]["id"] as? String, "q1")
        XCTAssertEqual(fleet.sent[0]["approved"] as? Bool, true)
        XCTAssertEqual(fleet.sent[0]["always"] as? Bool, true)
        XCTAssertTrue(client.sent.isEmpty, "the voice backend doesn't hold approvals")
        XCTAssertEqual(state.approvals.map(\.id), ["q2"])
    }

    func testDenyIsNotAlways() {
        let (state, _, fleet) = makeState([:])
        state.apply(["type": "approvals", "list": [approvalRow("q1")]])
        state.answer(state.approvals[0], approved: false)
        XCTAssertEqual(fleet.sent[0]["approved"] as? Bool, false)
        XCTAssertEqual(fleet.sent[0]["always"] as? Bool, false)
    }

    func testSnoozedCardsAreForgottenOnceAnswered() {
        let (state, _, _) = makeState([:])
        state.apply(["type": "approvals", "list": [approvalRow("q1"), approvalRow("q2")]])
        state.snoozeApprovals()
        XCTAssertTrue(state.unseenApprovals.isEmpty)
        state.apply(["type": "approvals", "list": [approvalRow("q2"), approvalRow("q3")]])
        XCTAssertEqual(state.snoozed, ["q2"])
        XCTAssertEqual(state.unseenApprovals.map(\.id), ["q3"])
    }

    func testRiskAndAlwaysComeThrough() {
        let (state, _, _) = makeState([:])
        state.apply(["type": "approvals", "list": [approvalRow("q1", risky: true, canAlways: false)]])
        XCTAssertTrue(state.approvals[0].risky)
        XCTAssertFalse(state.approvals[0].canAlways)
    }

    func testANewQuestionMakesASoundTypingOnlyButNotTheOnesAlreadyWaiting() {
        let (state, _, _) = makeState(["voice": false])
        var chimes: [AgentState.Chime] = []
        state.play = { chimes.append($0) }
        state.apply(["type": "approvals", "list": [approvalRow("q1")]])
        XCTAssertEqual(chimes, [], "what was waiting at connect isn't news")
        state.apply(["type": "approvals", "list": [approvalRow("q1"), approvalRow("q2")]])
        XCTAssertEqual(chimes, [.attention])
        state.apply(["type": "approvals", "list": [approvalRow("q2")]])
        XCTAssertEqual(chimes, [.attention], "one going away is quiet")
    }

    func testWithSoundsAtTheirDefaultNothingChimes() {
        let (state, _, _) = makeState(["voice": true, "sounds": NSNull()])
        var chimes: [AgentState.Chime] = []
        state.play = { chimes.append($0) }
        state.apply(["type": "approvals", "list": []])
        state.apply(["type": "approvals", "list": [approvalRow("q1")]])
        XCTAssertEqual(chimes, [])
    }

    func testSoundsSettingWins() {
        let (state, _, _) = makeState(["voice": true, "sounds": true])
        var chimes: [AgentState.Chime] = []
        state.play = { chimes.append($0) }
        state.apply(["type": "approvals", "list": []])
        state.apply(["type": "approvals", "list": [approvalRow("q1")]])
        XCTAssertEqual(chimes, [.attention])
    }

    func testACardFindsItsAgentBySessionOrPid() {
        let (state, _, _) = makeState([:])
        state.apply(["type": "agents", "list": [agentRow("s1"), agentRow("s2", pid: 42)]])
        var byPid = approvalRow("q1", session: "unknown")
        byPid["pid"] = 42
        state.apply(["type": "approvals", "list": [approvalRow("q0", session: "s1"), byPid]])
        XCTAssertEqual(state.agent(for: state.approvals[0])?.id, "s1")
        XCTAssertEqual(state.agent(for: state.approvals[1])?.id, "s2")
    }

    func testAQuestionMakesTheFleetWaitOnYou() {
        let (state, _, _) = makeState([:])
        state.apply(["type": "approvals", "list": [approvalRow("q1")]])
        XCTAssertTrue(state.busy)
        XCTAssertEqual(state.mood, .waiting)
    }
}
