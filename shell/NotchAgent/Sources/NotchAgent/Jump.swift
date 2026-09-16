import AppKit

/// Bring the window a session lives in to the front.
///
/// Terminal and iTerm2 can be asked for the exact tab by tty (needs Automation
/// permission the first time). Everything else only gets its app activated —
/// editors don't expose which window holds which terminal.
enum Jump {
    private static let bundles: [String: String] = [
        "Terminal": "com.apple.Terminal",
        "iTerm2": "com.googlecode.iterm2",
        "Code": "com.microsoft.VSCode",
        "Cursor": "com.todesktop.230313mzl4w4u92",
        "Ghostty": "com.mitchellh.ghostty",
        "WezTerm": "com.github.wez.wezterm",
        "Warp": "dev.warp.Warp-Stable",
    ]

    static func canJump(host: String) -> Bool { bundles[host] != nil }

    static func to(host: String, tty: String) {
        let device = tty.isEmpty ? "" : "/dev/\(tty)"
        switch (host, device.isEmpty) {
        case ("Terminal", false):
            osascript("""
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(device)" then
                    set selected of t to true
                    set index of w to 1
                  end if
                end repeat
              end repeat
              activate
            end tell
            """)
        case ("iTerm2", false):
            osascript("""
            tell application "iTerm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(device)" then
                      select w
                      select t
                      select s
                    end if
                  end repeat
                end repeat
              end repeat
              activate
            end tell
            """)
        default:
            guard let bundle = bundles[host],
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
            else { return }
            app.activate()
        }
    }

    /// Off the main thread: the first run waits on the Automation prompt.
    private static func osascript(_ source: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        DispatchQueue.global(qos: .userInitiated).async {
            try? process.run()
            process.waitUntilExit()
        }
    }
}
