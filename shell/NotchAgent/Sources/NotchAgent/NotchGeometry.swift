import AppKit

/// Where the hardware notch actually is, and what to do on Macs that have none.
struct NotchGeometry {
    let screen: NSScreen
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let hasNotch: Bool

    /// The MacBook's own display whenever it's on, including at a resolution
    /// that hides the notch. Lid closed, the display with the menu bar.
    static func pick<S>(_ screens: [S], notched: (S) -> Bool, builtIn: (S) -> Bool) -> S? {
        screens.first(where: notched) ?? screens.first(where: builtIn) ?? screens.first
    }

    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        return id.map { CGDisplayIsBuiltin($0) != 0 } ?? false
    }

    /// nil only in the moment macOS has no displays at all, mid-reconfiguration.
    static func current() -> NotchGeometry? {
        guard let screen = pick(NSScreen.screens, notched: { $0.safeAreaInsets.top > 0 }, builtIn: isBuiltIn) else {
            return nil
        }
        let inset = screen.safeAreaInsets.top
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        let measured = screen.frame.width - left - right
        let hasNotch = inset > 0 && left > 0 && right > 0
        return NotchGeometry(
            screen: screen,
            notchWidth: hasNotch ? measured : 180,
            notchHeight: hasNotch ? inset : 32,
            hasNotch: hasNotch
        )
    }

    /// Frame for the window, in screen coordinates, sized to hold the expanded panel.
    func windowFrame(expandedWidth: CGFloat, expandedHeight: CGFloat) -> NSRect {
        let width = max(expandedWidth, notchWidth)
        let frame = screen.frame
        return NSRect(
            x: frame.midX - width / 2,
            y: frame.maxY - expandedHeight,
            width: width,
            height: expandedHeight
        )
    }
}
