import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NotchWindow?
    private var statusItem: NSStatusItem?
    private let state = AgentState()
    private var client: BridgeClient!
    private var agentsClient: BridgeClient!
    private var hotKeyMonitor: Any?
    private let pushToTalk = PushToTalk()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        TerminalWindow.installMenu()

        let geometry = NotchGeometry.current()
        let frame = geometry.windowFrame(expandedWidth: 520, expandedHeight: 480)
        let window = NotchWindow(
            contentRect: frame,
            rootView: NotchView(state: state, geometry: geometry)
        )
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        self.window = window

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
        client.connect()

        // The agents daemon is a separate process on its own port, so the roster
        // outlives the voice pipeline. Its socket dropping says nothing about the
        // voice agent's phase, so it must not touch it.
        agentsClient = BridgeClient(url: URL(string: "ws://127.0.0.1:8767")!)
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

        pushToTalk.onChange = { [weak self] down in self?.state.setTalking(down) }
        pushToTalk.install()
    }

    func applicationWillTerminate(_ notification: Notification) {
        client?.disconnect()
        agentsClient?.disconnect()
        if let monitor = hotKeyMonitor { NSEvent.removeMonitor(monitor) }
        pushToTalk.uninstall()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◎"
        let menu = NSMenu()
        menu.addItem(withTitle: pushToTalk.menuTitle, action: nil, keyEquivalent: "").isEnabled = false
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
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    /// Keys that work from any app. Needs Accessibility permission.
    ///
    /// - ⌥Space: shut it up.
    /// - ⌃⌥Y / ⌃⌥N: allow or deny the oldest open question.
    /// - ⌃⌥J: show the terminal it came from.
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
        guard flags.contains([.control, .option]), let top = state.topApproval else { return }
        switch code {
        case 16: state.answer(top, approved: true)    // Y
        case 45: state.answer(top, approved: false)   // N
        case 38: state.jump(to: top)                  // J
        default: break
        }
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
        guard let path = PathPrompt.ask() else { return }
        state.startAgent(in: path)
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
