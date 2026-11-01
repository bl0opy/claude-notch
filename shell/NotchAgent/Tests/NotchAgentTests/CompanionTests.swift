import XCTest
@testable import NotchAgent

/// The notch beside the Claude app: questions that drop down on their own,
/// say why, and can be asked about; each session's chat; done lines that say
/// what was done.
@MainActor
final class CompanionTests: XCTestCase {
    func testAQuestionDropsDownWithoutHovering() {
        let (state, _, _) = makeState(["voice": false])
        XCTAssertEqual(state.islandMode, .compact)
        state.apply(["type": "approvals", "list": [approvalRow("a1")]])
        XCTAssertEqual(state.islandMode, .question)
    }

    func testHidingAQuestionPutsItBackInThePill() {
        let (state, _, _) = makeState(["voice": false])
        state.apply(["type": "approvals", "list": [approvalRow("a1")]])
        state.snoozeApprovals()
        XCTAssertEqual(state.islandMode, .compact)
        state.apply(["type": "approvals", "list": [approvalRow("a1"), approvalRow("a2")]])
        XCTAssertEqual(state.islandMode, .question, "a new one drops down again")
    }

    func testHoverStillOpensTheWholePanel() {
        let (state, _, _) = makeState(["voice": false])
        state.apply(["type": "approvals", "list": [approvalRow("a1")]])
        state.hovering = true
        XCTAssertEqual(state.islandMode, .expanded)
    }

    func testAQuestionOutranksANotice() {
        let (state, _, _) = makeState(["voice": false])
        state.apply(["type": "fleet_event", "event": "stuck", "sessionId": "s2", "project": "orbit", "line": "orbit looks stuck"])
        state.apply(["type": "approvals", "list": [approvalRow("a1")]])
        XCTAssertEqual(state.islandMode, .question)
    }

    func testWhyAndTheAlwaysRuleComeThrough() {
        let (state, _, _) = makeState(["voice": false])
        state.apply(["type": "approvals", "list": [approvalRow("a1", why: "Pushing the fix.", always: "Bash(git push:*)")]])
        XCTAssertEqual(state.approvals.first?.why, "Pushing the fix.")
        XCTAssertEqual(state.approvals.first?.always, "Bash(git push:*)")
    }

    func testAskingWhyDeniesWithAQuestionForTheAgent() {
        let (state, _, fleet) = makeState(["voice": false])
        state.apply(["type": "approvals", "list": [approvalRow("a1")]])
        state.ask(state.approvals[0])
        XCTAssertEqual(fleet.types, ["approve"])
        XCTAssertEqual(fleet.sent[0]["approved"] as? Bool, false)
        XCTAssertEqual(fleet.sent[0]["how"] as? String, AgentState.askWhy)
        XCTAssertTrue(state.approvals.isEmpty)
    }

    func testOpeningThePanelAsksForTheTargetsChat() {
        let (state, _, fleet) = makeState(["voice": false])
        state.apply(["type": "agents", "list": [desktopRow("s1", state: "working")]])
        state.hovering = true
        XCTAssertEqual(fleet.types.last, "chat")
        XCTAssertEqual(fleet.sent.last?["id"] as? String, "s1")
    }

    func testAClosedPanelDoesntPoll() {
        let (state, _, fleet) = makeState(["voice": false])
        state.apply(["type": "agents", "list": [desktopRow("s1")]])
        state.settle()
        XCTAssertFalse(fleet.types.contains("chat"))
    }

    func testOnlyTheTargetsChatIsShown() {
        let (state, _, _) = makeState(["voice": false])
        state.apply(["type": "agents", "list": [desktopRow("s1"), desktopRow("s2")]])
        state.focus("s1")
        state.apply(["type": "chat", "id": "s2", "rows": [["role": "you", "text": "not this"]]])
        XCTAssertTrue(state.chat.isEmpty)
        state.apply(["type": "chat", "id": "s1", "rows": [
            ["role": "you", "text": "fix it"], ["role": "tool", "text": "Edit(a.py)"],
            ["role": "claude", "text": "Fixed."], ["role": "mystery", "text": "dropped"],
        ]])
        XCTAssertEqual(state.chat.map(\.role), [.you, .tool, .claude])
        XCTAssertEqual(state.chatFor, "s1")
    }

    func testSwitchingSessionsClearsTheOldChat() {
        let (state, _, fleet) = makeState(["voice": false])
        state.apply(["type": "agents", "list": [desktopRow("s1"), desktopRow("s2")]])
        state.focus("s1")
        state.apply(["type": "chat", "id": "s1", "rows": [["role": "you", "text": "fix it"]]])
        state.focus("s2")
        XCTAssertTrue(state.chat.isEmpty, "no flash of the other session's chat")
        XCTAssertEqual(fleet.sent.last?["id"] as? String, "s2")
    }

    func testADesktopSessionIsCalledByItsTitleAndSaysWhatItLastDid() {
        let (state, _, _) = makeState(["voice": false])
        state.apply(["type": "agents", "list": [desktopRow("s1", title: "Fix the heart button", summary: "pushed b204d20")]])
        let agent = state.agents[0]
        XCTAssertTrue(agent.desktop)
        XCTAssertTrue(agent.canJump)
        XCTAssertEqual(agent.label, "Fix the heart button")
        XCTAssertEqual(agent.subtitle, "pushed b204d20")
        XCTAssertFalse(state.canInterrupt, "a session in the app can't be stopped from here")
    }

    func testDoneSaysWhatItAnswered() {
        let (state, _, _) = makeState(["voice": false])
        state.apply(["type": "fleet_event", "event": "done", "sessionId": "s1", "project": "orbit",
                     "long": true, "seconds": 300, "line": "The viewer loads glTF now."])
        XCTAssertEqual(state.notice?.line, "Done: The viewer loads glTF now.")
    }

    func testDoneWithoutAnAnswerFallsBackToHowLong() {
        let (state, _, _) = makeState(["voice": false])
        state.apply(["type": "fleet_event", "event": "done", "sessionId": "s1", "project": "orbit",
                     "long": true, "seconds": 300])
        XCTAssertEqual(state.notice?.line, "orbit done after 5 minutes")
    }

    func testShowsWithTheAppOrWhenThereIsNoAppToFollow() {
        XCTAssertTrue(ClaudeApp.shouldShow(follow: true, installed: true, running: true))
        XCTAssertFalse(ClaudeApp.shouldShow(follow: true, installed: true, running: false))
        XCTAssertTrue(ClaudeApp.shouldShow(follow: true, installed: false, running: false))
        XCTAssertTrue(ClaudeApp.shouldShow(follow: false, installed: true, running: false))
    }

    func testFollowingTheAppIsOnUnlessTurnedOff() {
        useSettings([:])
        XCTAssertTrue(Settings.followClaudeApp)
        useSettings(["follow_claude_app": false])
        XCTAssertFalse(Settings.followClaudeApp)
    }

    func testHidingLetsGoOfTheCursorAndKeyboard() {
        let (state, _, _) = makeState(["voice": false])
        state.hovering = true
        state.requestCompose()
        state.setHidden(true)
        XCTAssertFalse(state.hovering)
        XCTAssertFalse(state.composing)
    }

    func testAHiddenNotchMakesNoSound() {
        let (state, _, _) = makeState(["voice": false])
        var played: [AgentState.Chime] = []
        state.play = { played.append($0) }
        state.apply(["type": "approvals", "list": []])
        state.setHidden(true)
        state.apply(["type": "approvals", "list": [approvalRow("a1")]])
        XCTAssertTrue(played.isEmpty)
        state.setHidden(false)
        state.apply(["type": "approvals", "list": [approvalRow("a1"), approvalRow("a2")]])
        XCTAssertEqual(played, [.attention])
    }

    func testComingBackIsThePillNotFolded() {
        let (state, _, _) = makeState(["voice": false, "notch_fold_after": 1])
        state.apply(["type": "agents", "list": []])
        state.setHidden(true)
        state.setHidden(false)
        XCTAssertFalse(state.dormant)
    }

    func testTheNotchGoesOnTheMacBooksDisplayWhereverItIsInTheList() {
        struct Display { let name: String; var notched = false; var builtIn = false }
        func pick(_ displays: [Display]) -> String? {
            NotchGeometry.pick(displays, notched: \.notched, builtIn: \.builtIn)?.name
        }
        let macbook = Display(name: "macbook", notched: true, builtIn: true)
        let external = Display(name: "external")
        XCTAssertEqual(pick([external, macbook]), "macbook", "even with the external as the main display")
        XCTAssertEqual(pick([macbook, external]), "macbook")
        XCTAssertEqual(pick([external, Display(name: "macbook", builtIn: true)]), "macbook", "at a resolution hiding the notch")
        XCTAssertEqual(pick([external, Display(name: "other")]), "external", "lid closed: the display with the menu bar")
        XCTAssertNil(pick([]))
    }

    func testHostedAgentsAreOffUnlessAskedFor() {
        let (off, _, _) = makeState(["voice": false])
        XCTAssertFalse(off.hostedAgents)
        let (on, _, _) = makeState(["voice": false, "hosted_agents": true])
        XCTAssertTrue(on.hostedAgents)
    }
}
