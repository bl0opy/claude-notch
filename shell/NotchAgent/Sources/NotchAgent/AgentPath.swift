import Foundation

/// Where a new agent starts: what's typed, resolved against
/// `default_agent_path`, and the folders that could finish it.
///
/// A bare name like `bus-tracker` is taken relative to the default; `~` and
/// absolute paths work too.
enum AgentPath {
    static var base: String { expand(Settings.defaultAgentPath) }

    /// What the field starts with: the default, ready for a name after it.
    static var initial: String {
        let path = Settings.defaultAgentPath
        return path.hasSuffix("/") ? path : path + "/"
    }

    static func resolve(_ typed: String, against base: String = base) -> String {
        let path = expand(typed.trimmingCharacters(in: .whitespacesAndNewlines))
        let full = path.hasPrefix("/") ? path : (base as NSString).appendingPathComponent(path)
        return (full as NSString).standardizingPath
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Folders that finish what's typed, as it would be typed: `~/co` offers
    /// `~/code/`. Hidden ones only once a dot is typed.
    static func suggestions(for typed: String, against base: String = base, limit: Int = 5) -> [String] {
        let (typedDir, prefix) = split(typed)
        let dir = resolve(typedDir.isEmpty ? "." : typedDir, against: base)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        let lower = prefix.lowercased()
        return names
            .filter { name in
                (prefix.hasPrefix(".") || !name.hasPrefix("."))
                    && name.lowercased().hasPrefix(lower)
                    && name != prefix
                    && isDirectory((dir as NSString).appendingPathComponent(name))
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .prefix(limit)
            .map { typedDir + $0 + "/" }
    }

    /// "~/code/bus" → ("~/code/", "bus").
    private static func split(_ typed: String) -> (String, String) {
        guard let slash = typed.lastIndex(of: "/") else { return ("", typed) }
        return (String(typed[...slash]), String(typed[typed.index(after: slash)...]))
    }

    private static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
