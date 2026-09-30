import Foundation
import XCTest
@testable import NotchAgent

/// Everything the state sends, in order.
@MainActor
final class Recorder: MessageSink {
    var sent: [[String: Any]] = []
    func send(_ payload: [String: Any]) { sent.append(payload) }
    var types: [String] { sent.compactMap { $0["type"] as? String } }
}

/// A settings.json of the test's own, pointed at through NOTCH_SETTINGS the
/// way run.sh does it.
func useSettings(_ values: [String: Any]) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("notch-tests-\(UUID().uuidString).json")
    let data = try! JSONSerialization.data(withJSONObject: values)
    try! data.write(to: url)
    setenv("NOTCH_SETTINGS", url.path, 1)
}

func agentRow(_ id: String, state: String = "idle", project: String? = nil, host: String = "Terminal",
              pid: Int = 0) -> [String: Any] {
    ["id": id, "project": project ?? id, "state": state, "host": host, "pid": pid,
     "branch": "main", "reachable": true]
}

func approvalRow(_ id: String, session: String = "s1", project: String = "orbit", risky: Bool = false,
                 canAlways: Bool = true) -> [String: Any] {
    ["id": id, "source": "terminal", "sessionId": session, "pid": 0, "project": project, "tool": "Bash",
     "detail": "git push", "summary": "push to git", "risky": risky, "canAlways": canAlways,
     "created": Date().timeIntervalSince1970 * 1000]
}

@MainActor
func makeState(_ settings: [String: Any]) -> (AgentState, client: Recorder, fleet: Recorder) {
    useSettings(settings)
    let state = AgentState()
    let client = Recorder()
    let fleet = Recorder()
    state.attach(client, fleet: fleet)
    state.play = { _ in }
    state.rosterConnected = true
    return (state, client, fleet)
}
