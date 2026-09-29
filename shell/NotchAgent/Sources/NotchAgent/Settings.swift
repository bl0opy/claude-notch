import Foundation

/// `settings.json` at the repo root. Read on every use, so an edit applies
/// without restarting the notch.
///
/// run.sh points `NOTCH_SETTINGS` at it; without that, the working directory.
enum Settings {
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

    /// Where "New agent…" starts you off. Home if it isn't set.
    static var defaultAgentPath: String {
        (load()["default_agent_path"] as? String) ?? "~"
    }

    /// Seconds of quiet before the pill folds into the notch. 0 keeps it up.
    static var foldAfter: TimeInterval {
        let seconds = (load()["notch_fold_after"] as? NSNumber)?.doubleValue ?? 300
        return seconds <= 0 ? .infinity : seconds
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
