import AppKit

/// Hold a modifier key to talk, let go when you're done.
///
/// The key is watched with global event monitors, so it works in whatever app is
/// frontmost — it never reaches that app as a shortcut, because the default is a
/// key nothing binds on its own. Needs Accessibility permission, same as the
/// ⌥Space interrupt.
///
/// Set `PTT_KEY` to pick the key: `rightOption` (default), `rightCommand`,
/// `fn`, `leftOption` or `command`. Plain `command` is the old behaviour — it's
/// half of every shortcut on the machine, so there it has to be held alone past
/// `holdDelay` and anything else pressed cancels the hold.
@MainActor
final class PushToTalk {
    enum Key: String {
        case rightOption, rightCommand, fn, leftOption, command

        static var configured: Key {
            let raw = ProcessInfo.processInfo.environment["PTT_KEY"]
                ?? UserDefaults.standard.string(forKey: "PTTKey")
                ?? ""
            return Key(rawValue: raw) ?? .rightOption
        }

        /// Physical key. `command` matches either side, so it has no code.
        var keyCode: UInt16? {
            switch self {
            case .rightOption: return 61
            case .rightCommand: return 54
            case .fn: return 63
            case .leftOption: return 58
            case .command: return nil
            }
        }

        /// Device-dependent bit that says this exact key is down.
        var mask: UInt {
            switch self {
            case .rightOption: return 0x040
            case .leftOption: return 0x020
            case .rightCommand: return 0x0010
            case .fn: return UInt(NSEvent.ModifierFlags.function.rawValue)
            case .command: return UInt(NSEvent.ModifierFlags.command.rawValue)
            }
        }

        /// A key that's half of other shortcuts can't open the mic on a tap.
        var needsHold: Bool { self == .command }

        var label: String {
            switch self {
            case .rightOption: return "right ⌥"
            case .leftOption: return "left ⌥"
            case .rightCommand: return "right ⌘"
            case .fn: return "fn"
            case .command: return "⌘"
            }
        }
    }

    /// Cached so the UI can name the key without re-reading the environment.
    static let key = Key.configured

    var onChange: ((Bool) -> Void)?

    let key = PushToTalk.key

    private let holdDelay: TimeInterval = 0.2
    private var monitors: [Any] = []
    private var arming: DispatchWorkItem?
    private var open = false
    private var keyDown = false

    var menuTitle: String { "Hold \(key.label) to talk" }

    func install() {
        watch(.flagsChanged) { [weak self] event in self?.flagsChanged(event) }
        if key.needsHold {
            watch([.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] _ in
                self?.cancelHold()
            }
        }
    }

    func uninstall() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        close()
    }

    private func watch(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> Void) {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            Task { @MainActor in handler(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            Task { @MainActor in handler(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func flagsChanged(_ event: NSEvent) {
        if let code = key.keyCode, event.keyCode != code { return }

        let down: Bool
        if key == .command {
            // Held alone: any other modifier means it's a shortcut in progress.
            down = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command]
        } else {
            down = event.modifierFlags.rawValue & key.mask == key.mask
        }
        guard down != keyDown else { return }
        keyDown = down

        guard down else {
            cancelHold()
            close()
            return
        }

        guard key.needsHold else { return openMic() }
        let arm = DispatchWorkItem { [weak self] in
            self?.arming = nil
            self?.openMic()
        }
        arming = arm
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: arm)
    }

    /// The key turned out to be part of a shortcut, not a hold — leave the mic alone.
    private func cancelHold() {
        arming?.cancel()
        arming = nil
    }

    private func openMic() {
        guard keyDown, !open else { return }
        open = true
        onChange?(true)
    }

    private func close() {
        guard open else { return }
        open = false
        onChange?(false)
    }
}
