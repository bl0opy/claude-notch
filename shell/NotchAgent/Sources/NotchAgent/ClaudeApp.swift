import AppKit

/// The Claude desktop app, for keeping the notch up only while it's open.
///
/// launchd starts the notch at login and it stays hidden until the app launches.
/// macOS says when any app launches or quits, so nothing here polls.
@MainActor
final class ClaudeApp {
    nonisolated static let bundleId = "com.anthropic.claudefordesktop"

    /// Without the app installed there's nothing to wait for, so a notch
    /// following it would never appear.
    static func shouldShow(follow: Bool, installed: Bool, running: Bool) -> Bool {
        !follow || !installed || running
    }

    static var installed: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
    }

    static var running: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    static var shouldShowNow: Bool {
        shouldShow(follow: Settings.followClaudeApp, installed: installed, running: running)
    }

    static var frontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId
    }

    /// Calls back with whether the app is in front, whenever that may have changed.
    static func observeFrontmost(_ changed: @escaping @MainActor (Bool) -> Void) -> NSObjectProtocol {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let front = app?.bundleIdentifier == bundleId
            MainActor.assumeIsolated { changed(front) }
        }
    }

    /// Calls back whenever the app launches or quits.
    static func observe(_ changed: @escaping @MainActor () -> Void) -> [NSObjectProtocol] {
        let center = NSWorkspace.shared.notificationCenter
        return [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == bundleId else { return }
                MainActor.assumeIsolated { changed() }
            }
        }
    }
}
