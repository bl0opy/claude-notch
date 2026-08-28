import AppKit

/// Hold ⌘ to talk, let go when you're done.
///
/// Command is also half of every shortcut on the machine, so a tap must not open
/// the mic: the key has to be held alone past `holdDelay`, and anything else
/// pressed or clicked while it's down cancels the hold. Needs Accessibility
/// permission, same as the ⌥Space interrupt.
@MainActor
final class PushToTalk {
    var onChange: ((Bool) -> Void)?

    private let holdDelay: TimeInterval = 0.2
    private var monitors: [Any] = []
    private var arming: DispatchWorkItem?
    private var open = false
    private var commandDown = false

    func install() {
        watch(.flagsChanged) { [weak self] event in self?.flagsChanged(event) }
        watch([.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] _ in
            self?.cancelHold()
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
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let down = flags == [.command]
        guard down != commandDown else { return }
        commandDown = down

        if down {
            let arm = DispatchWorkItem { [weak self] in
                self?.arming = nil
                self?.openMic()
            }
            arming = arm
            DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: arm)
        } else {
            cancelHold()
            close()
        }
    }

    /// ⌘ turned out to be a shortcut, not a hold — leave the mic alone.
    private func cancelHold() {
        arming?.cancel()
        arming = nil
    }

    private func openMic() {
        guard commandDown, !open else { return }
        open = true
        onChange?(true)
    }

    private func close() {
        guard open else { return }
        open = false
        onChange?(false)
    }
}
