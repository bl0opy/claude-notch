import AppKit

/// Pick a repo to start an agent in.
///
/// The notch is an accessory app with a non-activating panel, so the open panel
/// has to be raised deliberately or it opens behind whatever you were using.
@MainActor
enum ProjectPicker {
    static func chooseDirectory(startingAt path: String = "") -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Start agent"
        panel.message = "Pick the repo the new agent should work in"
        if !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
