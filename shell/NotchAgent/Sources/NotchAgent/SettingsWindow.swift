import AppKit
import SwiftUI

/// ◎ → Settings…: a small window over `settings.json`. Every control writes
/// straight through, so there's no save button and the file stays the truth.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow?

    func show() {
        if let window {
            present(window)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Notch Agent Settings"
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(white: 0.06, alpha: 1)
        window.contentView = NSHostingView(rootView: SettingsView())
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        present(window)
    }

    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.level = .statusBar + 2
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        DockIcon.release(closing: notification.object as? NSWindow)
    }
}

/// The notch is an accessory app. A titled window of its own needs it to be a
/// regular one while open, so it can be ⌘-tabbed to and gets the Edit menu.
@MainActor
enum DockIcon {
    /// Back to accessory once the last titled window is gone.
    static func release(closing: NSWindow?) {
        let others = NSApp.windows.contains {
            $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled)
        }
        if !others { NSApp.setActivationPolicy(.accessory) }
    }
}

private struct SettingsView: View {
    @State private var voice = Settings.voice
    @State private var talkKey = PushToTalk.key
    @State private var agentPath = Settings.defaultAgentPath
    @State private var foldAfter = Settings.foldAfterSeconds
    @State private var sounds = Settings.sounds(voice: Settings.voice)
    @State private var hostedAgents = Settings.hostedAgents
    @State private var followApp = Settings.followClaudeApp
    private let voiceAtLaunch = Settings.voice
    private let hostedAtLaunch = Settings.hostedAgents

    private static let foldChoices: [(String, Double)] = [
        ("30 seconds", 30), ("1 minute", 60), ("5 minutes", 300), ("15 minutes", 900), ("never", 0),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("input") {
                Picker("", selection: $voice) {
                    Text("voice and typing").tag(true)
                    Text("typing only").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: voice) { _, value in Settings.set("voice", value) }

                note(voice
                     ? "Hold the talk key to speak; type from the notch any time. Voice needs Apple Silicon and the voice extras."
                     : "No mic, no speech models. Type from the notch (⌃⌥T) to message or steer any session.")
                if voice != voiceAtLaunch {
                    note("Restart ./run.sh for this to take effect.", tint: AgentPhase.waiting.tint)
                }
            }

            section("talk key") {
                Picker("", selection: $talkKey) {
                    ForEach(PushToTalk.Key.all, id: \.self) { key in
                        Text(key.label).tag(key)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                .disabled(!voice)
                .onChange(of: talkKey) { _, key in Settings.set("talk_key", key.rawValue) }
                if ProcessInfo.processInfo.environment["PTT_KEY"] != nil {
                    note("PTT_KEY is set in the environment and overrides this.", tint: AgentPhase.waiting.tint)
                }
            }

            section("sounds") {
                Toggle("a sound for new questions, stuck agents and long turns finishing", isOn: $sounds)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 11))
                    .onChange(of: sounds) { _, value in Settings.set("sounds", value) }
            }

            section("when to show") {
                Toggle("only while the Claude app is open", isOn: $followApp)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 11))
                    .onChange(of: followApp) { _, value in Settings.set("follow_claude_app", value) }
            }

            section("agents") {
                Toggle("start agents from the notch, in its own terminal window", isOn: $hostedAgents)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 11))
                    .onChange(of: hostedAgents) { _, value in Settings.set("hosted_agents", value) }
                note(hostedAgents
                     ? "A + after the sessions in the panel starts one."
                     : "Off, the notch watches and answers the sessions you already run.")
                if hostedAgents != hostedAtLaunch {
                    note("Restart ./run.sh for this to take effect.", tint: AgentPhase.waiting.tint)
                }
            }

            if hostedAgents {
                section("new agents start in") {
                    HStack(spacing: 8) {
                        TextField("~", text: $agentPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit { Settings.set("default_agent_path", agentPath) }
                        Button("Choose…", action: choose)
                    }
                    note("Bare names like bus-tracker are taken relative to this.")
                }
            }

            section("fold into the notch after") {
                Picker("", selection: $foldAfter) {
                    ForEach(Self.foldChoices, id: \.1) { choice in
                        Text(choice.0).tag(choice.1)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                .onChange(of: foldAfter) { _, value in Settings.set("notch_fold_after", value) }
            }

            Spacer(minLength: 0)
            HStack {
                Text(Settings.url.path(percentEncoded: false))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(white: 0.4))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([Settings.url]) }
                    .controlSize(.small)
            }
        }
        .padding(24)
        .frame(width: 460, height: 620, alignment: .topLeading)
        .onDisappear { Settings.set("default_agent_path", agentPath) }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(white: 0.5))
            content()
        }
    }

    private func note(_ text: String, tint: Color = Color(white: 0.45)) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: (agentPath as NSString).expandingTildeInPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path = url.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        agentPath = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        Settings.set("default_agent_path", agentPath)
    }
}
