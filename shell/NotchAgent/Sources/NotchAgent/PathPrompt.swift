import AppKit

/// Type the directory to start an agent in.
///
/// Starts filled in with `default_agent_path` from settings.json. A bare name
/// like `bus-tracker` is taken relative to it; `~` and absolute paths are too.
///
/// The notch is an accessory app with a non-activating panel, so the alert has
/// to be raised deliberately or it opens behind whatever you were using.
@MainActor
enum PathPrompt {
    static func ask() -> String? {
        let base = expand(Settings.defaultAgentPath)
        var text = base.hasSuffix("/") ? base : base + "/"
        var problem: String?

        while true {
            let alert = NSAlert()
            alert.messageText = "Start agent"
            alert.informativeText = problem ?? "The directory the new agent should work in"
            alert.addButton(withTitle: "Start")
            alert.addButton(withTitle: "Cancel")

            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
            field.stringValue = text
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.window.level = .modalPanel

            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }

            text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = resolve(text, against: base)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return path
            }
            problem = "No directory at \(path)"
        }
    }

    private static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private static func resolve(_ typed: String, against base: String) -> String {
        let path = expand(typed)
        let full = path.hasPrefix("/") ? path : (base as NSString).appendingPathComponent(path)
        return (full as NSString).standardizingPath
    }
}
