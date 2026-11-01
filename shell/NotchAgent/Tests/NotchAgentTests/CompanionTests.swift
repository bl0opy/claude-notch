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

    func testAskingWhyLeavesTheQuestionOpen() {
        let (state, _, fleet) = makeState(["voice": false])
        state.apply(["type": "approvals", "list": [approvalRow("a1")]])
        state.explain(state.approvals[0])
        XCTAssertEqual(fleet.types, ["explain"])
        XCTAssertEqual(fleet.sent[0]["id"] as? String, "a1")
        XCTAssertEqual(state.approvals.map(\.id), ["a1"], "no answer was given")
    }

    func testTheExplanationComesThroughOnTheCard() {
        let (state, _, _) = makeState(["voice": false])
        var row = approvalRow("a1")
        row["explaining"] = true
        state.apply(["type": "approvals", "list": [row]])
        XCTAssertTrue(state.approvals[0].explaining)
        row["explaining"] = false
        row["explanation"] = "Pushes main to origin."
        state.apply(["type": "approvals", "list": [row]])
        XCTAssertEqual(state.approvals[0].explanation, "Pushes main to origin.")
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

    func testMarkdownBlocks() {
        let blocks = MarkdownBlock.parse("""
        # Title
        one
        two

        - item
          - inner
        3. step
        > said
        ---
        ```swift
        let a = 1
        ```
        | A | B |
        |---|:-:|
        | 1 | 2 |
        tail
        """)
        XCTAssertEqual(blocks, [
            .heading("Title"), .paragraph("one\ntwo"), .bullet("item", depth: 0), .bullet("inner", depth: 1),
            .numbered("3.", text: "step"), .quote("said"), .rule, .code("let a = 1"),
            .table([["A", "B"], ["1", "2"]]), .paragraph("tail"),
        ])
    }

    func testAFenceClippedPartwayStillShows() {
        XCTAssertEqual(MarkdownBlock.parse("```\nlet a"), [.code("let a")])
    }

    func testTheSidebarPutsWhatNeedsYouFirst() {
        let (state, _, _) = makeState(["voice": false])
        var needy = desktopRow("needy", title: "Needy")
        needy["needs"] = "pick a colour"
        state.apply(["type": "agents", "list": [
            desktopRow("idle", title: "Idle"), desktopRow("busy", state: "working", title: "Busy"),
            needy, desktopRow("asking", state: "waiting", title: "Asking"), desktopRow("done", title: "Done"),
        ]])
        state.apply(["type": "fleet_event", "event": "done", "sessionId": "done", "project": "done", "long": false])
        XCTAssertEqual(state.sections.map(\.title), ["needs you", "finished", "working", "idle"])
        XCTAssertEqual(state.prioritized.map(\.id), ["asking", "needy", "done", "busy", "idle"])
        XCTAssertEqual(state.target?.id, "asking")
    }

    func testAQuestionPutsItsSessionUnderNeedsYou() {
        let (state, _, _) = makeState(["voice": false])
        state.apply(["type": "agents", "list": [desktopRow("a", title: "A"), desktopRow("b", title: "B")]])
        state.apply(["type": "approvals", "list": [approvalRow("q", session: "b")]])
        XCTAssertEqual(state.prioritized.first?.id, "b")
    }

    func testLookingAtAFinishedSessionClearsIt() {
        let (state, _, _) = makeState(["voice": false])
        state.apply(["type": "agents", "list": [desktopRow("a"), desktopRow("b")]])
        state.apply(["type": "fleet_event", "event": "done", "sessionId": "a", "project": "a", "long": false])
        XCTAssertTrue(state.unread.contains("a"))
        state.focus("a")
        XCTAssertFalse(state.unread.contains("a"))
    }

    func testAnOpenPanelStaysOnItsSessionThenResetsToWhatNeedsYou() {
        let (state, _, _) = makeState(["voice": false])
        state.apply(["type": "agents", "list": [desktopRow("a", title: "A"), desktopRow("b", title: "B")]])
        state.hovering = true
        XCTAssertEqual(state.target?.id, "a")
        state.apply(["type": "agents", "list": [desktopRow("a", title: "A"), desktopRow("b", state: "waiting", title: "B")]])
        XCTAssertEqual(state.target?.id, "a", "a reply mustn't go to whatever just became urgent")
        state.hovering = false
        XCTAssertEqual(state.target?.id, "b")
    }

    func testHostedAgentsAreOffUnlessAskedFor() {
        let (off, _, _) = makeState(["voice": false])
        XCTAssertFalse(off.hostedAgents)
        let (on, _, _) = makeState(["voice": false, "hosted_agents": true])
        XCTAssertTrue(on.hostedAgents)
    }
}
