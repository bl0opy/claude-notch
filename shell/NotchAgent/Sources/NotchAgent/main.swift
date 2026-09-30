import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NotchWindow?
    private var statusItem: NSStatusItem?
    private let state = AgentState()
    private var client: BridgeClient!
    private var agentsClient: BridgeClient!
    private var hotKeyMonitor: Any?
    private var mouse: MouseTracker?
    private let pushToTalk = PushToTalk()
    private var watchers: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        TerminalWindow.installMenu()

        let geometry = NotchGeometry.current()
        let frame = geometry.windowFrame(expandedWidth: 520, expandedHeight: 480)
        // Made before the window: the view reports the island's frame during
        // the window's first layout, and that report must land somewhere.
        let tracker = MouseTracker(state: state)
        let window = NotchWindow(
            contentRect: frame,
            rootView: NotchView(state: state, geometry: geometry) { tracker.island = $0 }
        )
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        self.window = window
        tracker.install(on: window)
        mouse = tracker

        client = BridgeClient()
        client.onMessage = { [weak self] message in self?.state.apply(message) }
        client.onConnectionChange = { [weak self] connected in
            guard let self else { return }
            if connected {
                // Ask for what the shell can't infer after a reconnect: who has
                // the mic, and which agents the backend started.
                self.client.send(["type": "hello"])
            } else {
                self.state.phase = .disconnected
            }
        }
        // Typing only, there's no voice backend to reach.
        if state.voice { client.connect() }

        // The agents daemon is a separate process on its own port, so the roster
        // outlives the voice pipeline. Its socket dropping says nothing about the
        // voice agent's phase, so it must not touch it.
        agentsClient = BridgeClient(url: Ports.agents)
        agentsClient.onMessage = { [weak self] message in self?.state.apply(message) }
        agentsClient.onConnectionChange = { [weak self] connected in
            if connected {
                self?.state.rosterConnected = true
            } else {
                self?.state.clearRoster()
            }
        }
        state.attach(client, fleet: agentsClient)
        agentsClient.connect()

        state.startClock()
        installStatusItem()
        installHotKey()

        if state.voice {
            pushToTalk.onChange = { [weak self] down in self?.state.setTalking(down) }
            pushToTalk.install()
            NotificationCenter.default.publisher(for: Settings.changed)
                .sink { [weak self] _ in
                    guard let self, PushToTalk.Key.configured != PushToTalk.key else { return }
                    self.pushToTalk.reload()
                    self.installStatusItem()
                }
                .store(in: &watchers)
        }

        // Clicking into another app ends typing, or the panel would stay open.
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: window)
            .sink { [weak self] _ in self?.state.endCompose() }
            .store(in: &watchers)

        // The notch takes the keyboard only while you're typing in it; done,
        // it goes back to whatever app you were in.
        // Debounced: moving from one field in the notch to the other is a
        // blur then a focus, and isn't done typing.
        state.$composing
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] composing in
                guard !composing, let window = self?.window, window.isKeyWindow,
                      let app = NSWorkspace.shared.frontmostApplication, app != .current else { return }
                app.activate()
            }
            .store(in: &watchers)
    }

    /// When run.sh started the agents daemon, quitting the notch takes the
    /// daemon down with it, and every session hosted in its ptys too. ⌘Q is
    /// muscle memory in a terminal, so busy ones are worth a question first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ProcessInfo.processInfo.environment["NOTCH_OWNS_DAEMON"] == "1" else { return .terminateNow }
        let busy = state.agents.filter { $0.hosted && ($0.state == .working || $0.state == .waiting) }
        guard !busy.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        let names = busy.map(\.project).filter { !$0.isEmpty }
        alert.messageText = busy.count == 1 ? "An agent is still working" : "\(busy.count) agents are still working"
        alert.informativeText = (names.isEmpty ? "" : names.joined(separator: ", ") + ". ")
            + "Quitting stops the agents daemon and every session in the terminal window."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        client?.disconnect()
        agentsClient?.disconnect()
        if let monitor = hotKeyMonitor { NSEvent.removeMonitor(monitor) }
        pushToTalk.uninstall()
        mouse?.uninstall()
    }

    private func installStatusItem() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◎"
        let menu = NSMenu()
        if state.voice {
            menu.addItem(withTitle: pushToTalk.menuTitle, action: nil, keyEquivalent: "").isEnabled = false
        }
        menu.addItem(
            withTitle: "Type to an agent (⌃⌥T)", action: #selector(compose), keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: "Interrupt (⌥Space)", action: #selector(interrupt), keyEquivalent: ""
        ).target = self
        menu.addItem(withTitle: "Allow / deny oldest (⌃⌥Y / ⌃⌥N)", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: "Show its terminal (⌃⌥J)", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Agents dashboard", action: #selector(showAgents), keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: "Terminal window", action: #selector(showTerminals), keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: "New agent…", action: #selector(newAgent), keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ","
        ).target = self
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    /// Keys that work from any app. Needs Accessibility permission.
    ///
    /// - ⌥Space: shut it up.
    /// - ⌃⌥Y / ⌃⌥N: allow or deny the oldest open question.
    /// - ⌃⌥J: show the terminal it came from.
    /// - ⌃⌥T: type to the focused agent.
    ///
    /// Global monitors can't swallow a key, so the approval keys use ⌃⌥ — nothing
    /// a terminal or an editor does anything with.
    private func installHotKey() {
        hotKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let code = event.keyCode
            Task { @MainActor in self?.handleHotKey(flags: flags, code: code) }
        }
    }

    private func handleHotKey(flags: NSEvent.ModifierFlags, code: UInt16) {
        if flags.contains(.option), !flags.contains(.control), code == 49 {
            state.interrupt()
            return
        }
        if flags.contains([.control, .option]), code == 17 {    // T
            compose()
            return
        }
        guard flags.contains([.control, .option]), let top = state.topApproval else { return }
        switch code {
        case 16: state.answer(top, approved: true)    // Y
        case 45: state.answer(top, approved: false)   // N
        case 38: state.jump(to: top)                  // J
        default: break
        }
    }

    @objc private func compose() {
        window?.makeKey()
        state.requestCompose()
    }

    @objc private func showSettings() {
        SettingsWindow.shared.show()
    }

    @objc private func interrupt() {
        state.interrupt()
    }

    @objc private func showAgents() {
        state.show(.agents)
    }

    @objc private func showTerminals() {
        TerminalWindow.shared.show()
    }

    @objc private func newAgent() {
        window?.makeKey()
        state.requestNewAgent()
    }
}

@MainActor
func launch() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    objc_setAssociatedObject(app, "NotchAgentDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}

MainActor.assumeIsolated { launch() }
