import XCTest
@testable import NotchAgent

/// Who a typed line goes to, and how it gets there.
@MainActor
final class TypingTests: XCTestCase {
    private let roster: [String: Any] = ["type": "agents", "list": [
        agentRow("term", state: "idle", host: "Terminal"),
        agentRow("hosted", state: "working", host: "window"),
    ]]

    func testTypingOnlyTargetsTheChosenRowElseAHostedOne() {
        let (state, _, _) = makeState(["voice": false])
        state.apply(roster)
        XCTAssertEqual(state.target?.id, "hosted")
        state.focused = "term"
        XCTAssertEqual(state.target?.id, "term")
    }

    func testWithVoiceNothingChosenIsTheVoiceAgent() {
        let (state, client, fleet) = makeState(["voice": true])
        state.apply(roster)
        XCTAssertNil(state.target)
        XCTAssertEqual(state.targetName, "the voice agent")
        state.send(text: "  hello  ")
        XCTAssertEqual(client.types, ["text"])
        XCTAssertEqual(client.sent[0]["text"] as? String, "hello")
        XCTAssertTrue(fleet.sent.isEmpty)
    }

    func testALineForARosterAgentGoesThroughTheDaemon() {
        let (state, client, fleet) = makeState(["voice": true])
        state.apply(roster)
        state.focused = "hosted"
        state.send(text: "try the other approach", steer: true)
        XCTAssertEqual(fleet.types, ["type"])
        XCTAssertEqual(fleet.sent[0]["id"] as? String, "hosted")
        XCTAssertEqual(fleet.sent[0]["steer"] as? Bool, true)
        XCTAssertTrue(client.sent.isEmpty)
    }

    func testBlankLinesAreNotSent() {
        let (state, _, fleet) = makeState(["voice": false])
        state.apply(roster)
        state.send(text: "   ")
        XCTAssertTrue(fleet.sent.isEmpty)
    }

    func testWhatBecameOfTheLineIsShown() {
        let (state, _, _) = makeState(["voice": false])
        state.apply(roster)
        state.focused = "term"
        state.send(text: "hi")
        XCTAssertTrue(state.typedStatus.hasPrefix("→"))
        state.apply(["type": "typed", "id": "term", "status": "queued"])
        XCTAssertTrue(state.typedStatus.contains("busy"), state.typedStatus)
        state.apply(["type": "typed", "id": "someone-else", "status": "gone"])
        XCTAssertTrue(state.typedStatus.contains("busy"), "another client's receipt isn't ours")
        state.apply(["type": "typed", "id": "term", "status": "waiting"])
        XCTAssertTrue(state.typedStatus.contains("permission"), state.typedStatus)
    }

    func testOnlyAHostedTargetCanBeInterruptedTypingOnly() {
        let (state, client, fleet) = makeState(["voice": false])
        state.apply(roster)
        state.focused = "term"
        XCTAssertFalse(state.canInterrupt)
        state.focused = "hosted"
        XCTAssertTrue(state.canInterrupt)
        state.interrupt()
        XCTAssertEqual(fleet.types, ["interrupt"])
        XCTAssertEqual(fleet.sent[0]["id"] as? String, "hosted")
        XCTAssertTrue(client.sent.isEmpty)
    }

    func testWithVoiceTheVoiceAgentIsInterruptedThroughTheBackend() {
        let (state, client, _) = makeState(["voice": true])
        state.interrupt()
        XCTAssertEqual(client.types, ["interrupt"])
    }
}

/// "+ agent", inline.
@MainActor
final class NewAgentTests: XCTestCase {
    private var root: String!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("notch-paths-\(UUID().uuidString)").path
        for dir in ["bus-tracker", "bus-stops", "orbit", ".hidden"] {
            try! FileManager.default.createDirectory(atPath: "\(root!)/\(dir)", withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: "\(root!)/bus-notes.txt", contents: nil)
    }

    func testResolving() {
        XCTAssertEqual(AgentPath.resolve("orbit", against: root), "\(root!)/orbit")
        XCTAssertEqual(AgentPath.resolve("/tmp", against: root), "/tmp")
        XCTAssertEqual(AgentPath.resolve("~", against: root), NSHomeDirectory())
        XCTAssertEqual(AgentPath.resolve("orbit/../bus-tracker", against: root), "\(root!)/bus-tracker")
    }

    func testSuggestionsAreFoldersThatFinishIt() {
        XCTAssertEqual(AgentPath.suggestions(for: "bus", against: root), ["bus-stops/", "bus-tracker/"])
        XCTAssertEqual(AgentPath.suggestions(for: "\(root!)/or", against: "/"), ["\(root!)/orbit/"])
        XCTAssertEqual(AgentPath.suggestions(for: "", against: root), ["bus-stops/", "bus-tracker/", "orbit/"])
        XCTAssertEqual(AgentPath.suggestions(for: ".h", against: root), [".hidden/"])
        XCTAssertEqual(AgentPath.suggestions(for: "nothing", against: root), [])
    }

    func testStartingInAFolderSendsASpawnAndClosesTheField() {
        let (state, _, fleet) = makeState(["default_agent_path": root!])
        state.requestNewAgent()
        XCTAssertTrue(state.addingAgent)
        XCTAssertEqual(state.panel, .agents)
        XCTAssertTrue(state.composing, "the panel holds open while you type the path")
        XCTAssertNil(state.submitNewAgent("orbit"))
        XCTAssertEqual(fleet.types, ["spawn"])
        XCTAssertEqual(fleet.sent[0]["cwd"] as? String, "\(root!)/orbit")
        XCTAssertFalse(state.addingAgent)
    }

    func testANonFolderSaysSoAndSendsNothing() {
        let (state, _, fleet) = makeState(["default_agent_path": root!])
        state.requestNewAgent()
        XCTAssertEqual(state.submitNewAgent("nope"), "no folder at \(root!)/nope")
        XCTAssertEqual(state.submitNewAgent("bus-notes.txt"), "no folder at \(root!)/bus-notes.txt")
        XCTAssertTrue(fleet.sent.isEmpty)
        XCTAssertTrue(state.addingAgent)
    }

    func testNoDaemonNoSpawn() {
        let (state, _, fleet) = makeState(["default_agent_path": root!])
        state.rosterConnected = false
        XCTAssertEqual(state.submitNewAgent("orbit"), "the agents daemon isn't running")
        XCTAssertTrue(fleet.sent.isEmpty)
    }

    func testTheFieldStartsAtTheDefault() {
        useSettings(["default_agent_path": "~/code"])
        XCTAssertEqual(AgentPath.initial, "~/code/")
    }
}

final class SettingsTests: XCTestCase {
    func testWritingKeepsWhatElseIsThere() throws {
        useSettings(["voice": false, "default_agent_path": "~/code"])
        Settings.set("notch_fold_after", 60)
        let data = try Data(contentsOf: Settings.url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["voice"] as? Bool, false)
        XCTAssertEqual(object?["default_agent_path"] as? String, "~/code")
        XCTAssertEqual(Settings.foldAfterSeconds, 60)
    }

    func testDefaults() {
        useSettings([:])
        XCTAssertTrue(Settings.voice)
        XCTAssertEqual(Settings.defaultAgentPath, "~")
        XCTAssertEqual(Settings.foldAfter, 300)
        XCTAssertFalse(Settings.sounds(voice: true))
        XCTAssertTrue(Settings.sounds(voice: false))
    }
}
