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
        state.apply(["type": "agents", "list": [desktopRow("s1", title: "Fix the streak counter", summary: "pushed b204d20")]])
        let agent = state.agents[0]
        XCTAssertTrue(agent.desktop)
        XCTAssertTrue(agent.canJump)
        XCTAssertEqual(agent.label, "Fix the streak counter")
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

    func testTheTokenIsReadFreshAndAMissingFileIsEmpty() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("token-\(UUID().uuidString)")
        setenv("NOTCH_TOKEN_FILE", url.path, 1)
        defer { unsetenv("NOTCH_TOKEN_FILE") }
        XCTAssertEqual(BridgeToken.read, "")
        try! "secret\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(BridgeToken.read, "secret")
    }

    func testInTheClaudeAppItStaysFolded() {
        let (state, _, _) = makeState(["voice": false])
        state.apply(["type": "agents", "list": [desktopRow("s1", state: "working")]])
        XCTAssertEqual(state.islandMode, .compact)
        state.claudeInFront = true
        XCTAssertEqual(state.islandMode, .dormant)
        state.apply(["type": "fleet_event", "event": "done", "sessionId": "s1", "project": "s1", "long": true, "seconds": 60])
        XCTAssertEqual(state.islandMode, .dormant, "no notices either")
    }

    func testInTheClaudeAppAQuestionIsACountThatDropsDownWhenYouLeave() {
        let (state, _, _) = makeState(["voice": false])
        state.claudeInFront = true
        state.apply(["type": "approvals", "list": [approvalRow("a1")]])
        XCTAssertEqual(state.islandMode, .compact)
        state.claudeInFront = false
        XCTAssertEqual(state.islandMode, .question)
    }

    func testInTheClaudeAppHoverStillOpensIt() {
        let (state, _, _) = makeState(["voice": false])
        state.claudeInFront = true
        state.hovering = true
        XCTAssertEqual(state.islandMode, .expanded)
    }

    func testInTheClaudeAppItMakesNoSound() {
        let (state, _, _) = makeState(["voice": false])
        var played: [AgentState.Chime] = []
        state.play = { played.append($0) }
        state.apply(["type": "approvals", "list": []])
        state.claudeInFront = true
        state.apply(["type": "approvals", "list": [approvalRow("a1")]])
        state.apply(["type": "fleet_event", "event": "done", "sessionId": "s1", "project": "s1", "long": true, "seconds": 60])
        XCTAssertTrue(played.isEmpty)
    }

    private func questionRow(multi: Bool = false) -> [String: Any] {
        var row = approvalRow("q1")
        row["tool"] = "AskUserQuestion"
        row["questions"] = [["question": "Which?", "header": "H", "multiSelect": multi,
                             "options": [["label": "Red", "description": "warm"], ["label": "Blue"]]]]
        return row
    }

    func testAQuestionsOptionsComeThrough() {
        let (state, _, _) = makeState(["voice": false])
        state.apply(["type": "approvals", "list": [questionRow(multi: true)]])
        let question = state.approvals[0].questions[0]
        XCTAssertEqual(question.options.map(\.label), ["Red", "Blue"])
        XCTAssertEqual(question.options[0].description, "warm")
        XCTAssertTrue(question.multiSelect)
        XCTAssertTrue(approvalRow("a")["questions"] == nil)
    }

    func testChoosingSendsTheAnswerAndTakesTheCardDown() {
        let (state, _, fleet) = makeState(["voice": false])
        state.apply(["type": "approvals", "list": [questionRow()]])
        state.choose(state.approvals[0], answers: ["Which?": "Red"])
        XCTAssertEqual(fleet.sent.last?["approved"] as? Bool, true)
        XCTAssertEqual((fleet.sent.last?["answers"] as? [String: Any])?["Which?"] as? String, "Red")
        XCTAssertTrue(state.approvals.isEmpty)
    }

    func testABareYesCantAnswerAQuestion() {
        let (state, _, fleet) = makeState(["voice": false])
        state.apply(["type": "approvals", "list": [questionRow()]])
        state.answer(state.approvals[0], approved: true)
        XCTAssertTrue(fleet.sent.isEmpty)
        XCTAssertEqual(state.approvals.count, 1, "⌃⌥Y mustn't clear it with no choice made")
        state.answer(state.approvals[0], approved: false)
        XCTAssertEqual(fleet.types, ["approve"], "no still works")
    }

    private func askCard(_ id: String = "c1", session: String = "s1") -> [String: Any] {
        ["id": id, "kind": "ask", "project": "orbit", "sessionId": session, "title": "How?", "fields": [
            ["name": "mode", "label": "Mode", "type": "choice", "options": ["A", "B"]],
            ["name": "size", "label": "Size", "type": "number", "min": 10, "max": 20, "step": 1],
            ["name": "on", "label": "On", "type": "toggle", "default": true],
            ["name": "tags", "label": "Tags", "type": "multichoice", "options": ["x", "y", "z"]],
            ["name": "note", "label": "Note", "type": "text"],
        ]]
    }

    func testAFormDropsDownAndWaitsOnYou() {
        let (state, _, _) = makeState(["voice": false])
        var played: [AgentState.Chime] = []
        state.play = { played.append($0) }
        state.apply(["type": "cards", "list": [askCard()]])
        XCTAssertEqual(state.islandMode, .question)
        XCTAssertEqual(state.waitingOnYou, 1)
        XCTAssertEqual(played, [.attention])
    }

    func testAFormOnlySendsOnceEveryFieldIsFilled() {
        let (state, _, fleet) = makeState(["voice": false])
        state.apply(["type": "cards", "list": [askCard()]])
        let card = state.cards[0]
        XCTAssertFalse(state.canSend(card))
        state.send(card)
        XCTAssertTrue(fleet.sent.isEmpty)

        state.set(.choice("B"), for: card.fields[0], in: card)
        state.set(.many(["z", "x"]), for: card.fields[3], in: card)
        state.set(.text("  "), for: card.fields[4], in: card)
        XCTAssertFalse(state.canSend(card), "blank text isn't an answer")
        state.set(.text("hi"), for: card.fields[4], in: card)
        XCTAssertTrue(state.canSend(card))

        state.send(card)
        XCTAssertEqual(fleet.types, ["card_answer"])
        let answers = fleet.sent[0]["answers"] as? [String: Any]
        XCTAssertEqual(answers?["mode"] as? String, "B")
        XCTAssertEqual(answers?["size"] as? Double, 10, "a slider starts at its minimum")
        XCTAssertEqual(answers?["on"] as? Bool, true)
        XCTAssertEqual(answers?["tags"] as? [String], ["x", "z"], "in the field's order")
        XCTAssertEqual(answers?["note"] as? String, "hi")
        XCTAssertTrue(state.cards.isEmpty)
    }

    func testDismissingTellsTheDaemon() {
        let (state, _, fleet) = makeState(["voice": false])
        state.apply(["type": "cards", "list": [askCard()]])
        state.dismiss(state.cards[0])
        XCTAssertEqual(fleet.types, ["card_dismiss"])
        XCTAssertTrue(state.cards.isEmpty)
    }

    func testAPassiveCardDropsDownButWaitsOnNobody() {
        let (state, _, _) = makeState(["voice": false])
        var played: [AgentState.Chime] = []
        state.play = { played.append($0) }
        state.apply(["type": "cards", "list": [["id": "c", "kind": "show", "title": "Uploading", "progress": 0.5]]])
        XCTAssertEqual(state.islandMode, .question)
        XCTAssertEqual(state.waitingOnYou, 0)
        XCTAssertEqual(state.cards[0].progress, 0.5)
        XCTAssertTrue(played.isEmpty)
    }

    func testInTheClaudeAppAFormIsACountAndAPassiveCardIsNothing() {
        let (state, _, _) = makeState(["voice": false])
        state.claudeInFront = true
        state.apply(["type": "cards", "list": [["id": "c", "kind": "show", "title": "Uploading"]]])
        XCTAssertEqual(state.islandMode, .dormant)
        state.apply(["type": "cards", "list": [askCard()]])
        XCTAssertEqual(state.islandMode, .compact)
    }

    func testAFormPutsItsSessionUnderNeedsYou() {
        let (state, _, _) = makeState(["voice": false])
        state.apply(["type": "agents", "list": [desktopRow("a", title: "A"), desktopRow("b", title: "B")]])
        state.apply(["type": "cards", "list": [askCard(session: "b")]])
        XCTAssertEqual(state.prioritized.first?.id, "b")
    }

    func testADraftGoesWithItsCard() {
        let (state, _, _) = makeState(["voice": false])
        state.apply(["type": "cards", "list": [askCard()]])
        state.set(.choice("A"), for: state.cards[0].fields[0], in: state.cards[0])
        state.apply(["type": "cards", "list": []])
        XCTAssertTrue(state.cardDrafts.isEmpty)
    }

    func testDiffFences() {
        XCTAssertEqual(MarkdownBlock.parse("```diff\n- a\n+ b\n```"), [.diff("- a\n+ b")])
        XCTAssertEqual(MarkdownBlock.parse("```swift\nlet a\n```"), [.code("let a")])
    }

    func testAFailedConnectionRetriesOnceNotTwice() async throws {
        // Nothing listens here. Doubling would be 7+ drops by now; backing off
        // from 0.5s, one chain of retries manages about 3.
        let client = BridgeClient(url: URL(string: "ws://127.0.0.1:18999")!)
        var drops = 0
        client.onConnectionChange = { connected in if !connected { drops += 1 } }
        client.connect()
        try await Task.sleep(for: .seconds(2.6))
        client.disconnect()
        XCTAssertGreaterThanOrEqual(drops, 2)
        XCTAssertLessThanOrEqual(drops, 4)
    }

    func testHostedAgentsAreOffUnlessAskedFor() {
        let (off, _, _) = makeState(["voice": false])
        XCTAssertFalse(off.hostedAgents)
        let (on, _, _) = makeState(["voice": false, "hosted_agents": true])
        XCTAssertTrue(on.hostedAgents)
    }
}
