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
}
