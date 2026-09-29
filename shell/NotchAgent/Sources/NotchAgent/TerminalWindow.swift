import AppKit
import WebKit

/// The window the agents daemon's hosted sessions are drawn in: its local page
/// in a web view, one terminal per session, no Terminal.app involved.
///
/// The notch is an accessory app with no Dock icon or menu bar. While this
/// window is open it becomes a regular one, so it can be ⌘-tabbed to and ⌘C/⌘V
/// reach the terminal.
@MainActor
final class TerminalWindow: NSObject, NSWindowDelegate {
    static let shared = TerminalWindow()

    private static var base: URL { Ports.window }

    private var window: NSWindow?
    private var webView: WKWebView?

    func show(session id: String? = nil) {
        if let webView, let window {
            if let id {
                webView.evaluateJavaScript("window.focusSession(\(Self.jsString(id)))")
            }
            present(window)
            return
        }
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        var url = Self.base
        if let id, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.fragment = id
            url = parts.url ?? url
        }
        webView.load(URLRequest(url: url))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Notch Agents"
        // A dark title bar the colour of the page, rather than content under it
        // fighting the traffic lights.
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(white: 0.04, alpha: 1)
        window.minSize = NSSize(width: 640, height: 400)
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("NotchAgentsTerminal")
        if !window.setFrameUsingName("NotchAgentsTerminal") { window.center() }

        self.window = window
        self.webView = webView
        present(window)
    }

    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
    }

    func windowWillClose(_ notification: Notification) {
        // The sessions live in the daemon; closing the window only stops drawing them.
        webView?.removeFromSuperview()
        webView = nil
        window = nil
        DockIcon.release(closing: notification.object as? NSWindow)
    }

    private static func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    /// Edit shortcuts only work through a main menu, and an accessory app has none.
    static func installMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}
