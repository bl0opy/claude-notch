import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NotchWindow?
    private var statusItem: NSStatusItem?
    private let state = AgentState()
    private var client: BridgeClient!
    private var hotKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let geometry = NotchGeometry.current()
        let frame = geometry.windowFrame(expandedWidth: 460, expandedHeight: 460)
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
            if !connected { self?.state.phase = .disconnected }
        }
        state.attach(client)
        client.connect()

        installStatusItem()
        installHotKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        client?.disconnect()
        if let monitor = hotKeyMonitor { NSEvent.removeMonitor(monitor) }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◎"
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Interrupt (⌥Space)", action: #selector(interrupt), keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    /// Option-Space anywhere = shut it up. Needs Accessibility permission.
    private func installHotKey() {
        hotKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.option), event.keyCode == 49 else { return }
            Task { @MainActor in self?.state.interrupt() }
        }
    }

    @objc private func interrupt() {
        state.interrupt()
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
