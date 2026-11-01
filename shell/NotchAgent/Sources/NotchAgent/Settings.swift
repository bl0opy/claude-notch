import Foundation

/// `settings.json` at the repo root. Read on every use, so an edit applies
/// without restarting the notch.
///
/// run.sh points `NOTCH_SETTINGS` at it; without that, the working directory.
enum Settings {
    /// Posted after the settings window writes a change.
    static let changed = Notification.Name("NotchSettingsChanged")

    static var url: URL {
        if let path = ProcessInfo.processInfo.environment["NOTCH_SETTINGS"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("settings.json")
    }

    private static func load() -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// Writes one key, keeping whatever else is in the file.
    static func set(_ key: String, _ value: Any) {
        var object = load()
        object[key] = value
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        try? data.write(to: url, options: .atomic)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Voice in and out. Off, the notch is typed to, and run.sh doesn't start
    /// the voice backend at all — which is what lets it run without Apple
    /// Silicon or the speech models. Read once at launch.
    static var voice: Bool {
        (load()["voice"] as? Bool) ?? true
    }

    /// A system sound for a new question, a stuck agent or a long turn
    /// finishing. On by default only when there's no voice to say so.
    static func sounds(voice: Bool) -> Bool {
        (load()["sounds"] as? Bool) ?? !voice
    }

    /// The push-to-talk key. `PTT_KEY` in the environment still wins.
    static var talkKey: String {
        (load()["talk_key"] as? String) ?? ""
    }

    /// Starting agents from the notch, and the terminal window they run in.
    /// Off by default: the notch watches the sessions you already run.
    static var hostedAgents: Bool {
        (load()["hosted_agents"] as? Bool) ?? false
    }

    /// Where "New agent…" starts you off. Home if it isn't set.
    static var defaultAgentPath: String {
        (load()["default_agent_path"] as? String) ?? "~"
    }

    /// Seconds of quiet before the pill folds into the notch. 0 keeps it up.
    static var foldAfterSeconds: Double {
        (load()["notch_fold_after"] as? NSNumber)?.doubleValue ?? 300
    }

    static var foldAfter: TimeInterval {
        foldAfterSeconds <= 0 ? .infinity : foldAfterSeconds
    }
}

/// Where the Python side listens: the same environment variables it reads, so
/// moving a port in the environment `run.sh` starts from moves it everywhere.
enum Ports {
    private static func port(_ name: String, _ fallback: Int) -> Int {
        ProcessInfo.processInfo.environment[name].flatMap(Int.init) ?? fallback
    }

    static var backend: URL { URL(string: "ws://127.0.0.1:\(port("WS_PORT", 8765))")! }
    static var agents: URL { URL(string: "ws://127.0.0.1:\(port("AGENTS_WS_PORT", 8767))")! }
    static var window: URL { URL(string: "http://127.0.0.1:\(port("AGENTS_WINDOW_PORT", 8768))/")! }
}
